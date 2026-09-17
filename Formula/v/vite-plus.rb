class VitePlus < Formula
  desc "Unified toolchain and entry point for web development"
  homepage "https://viteplus.dev"
  license "MIT"
  revision 1
  head "https://github.com/voidzero-dev/vite-plus.git", branch: "main"

  stable do
    url "https://github.com/voidzero-dev/vite-plus/archive/refs/tags/v0.3.2.tar.gz"
    sha256 "44d6ccdb5760300b3879e06a3929917321459f556a849de8b93fc02c01cbb964"

    # Temporary verification backport; remove after the upstream fix is released.
    # https://github.com/voidzero-dev/vite-plus/pull/2729
    # Rust changes through commit ba552493140eb950556a1dd04ff21231c014224e.
    patch :DATA
  end

  bottle do
    sha256 cellar: :any, arm64_golden_gate: "f4e963182626ea11ace0cad36f13e552dd10022ddda12744d1cc3e6b98a4c032"
    sha256 cellar: :any, arm64_tahoe:       "bc5bdf56f1006b1c051c24afbd0c7a44960fad03c76bb357491e029c78ad343a"
    sha256 cellar: :any, arm64_sequoia:     "c8ffd5c4ff375814a8d1bf032a6c5fd057b9482c0e2016ad52433222d36a251e"
    sha256               arm64_linux:       "a8559d5e9ab867e657077340605911c88efeacea22aa469d6b0d90dd84329155"
    sha256               x86_64_linux:      "13f91c849bbb591c5d24463aae69d4a76908a5f688b1d29e78f7b16ce52d0348"
  end

  depends_on "cmake" => :build
  depends_on "just" => :build
  depends_on "pnpm" => :build
  depends_on "rustup" => :build # TODO: try to restore stable rust: https://github.com/voidzero-dev/vite-task/commit/db99ba4d5d33323cc9e7b329f11bdea0610fbc7f
  depends_on "node"

  resource "rolldown" do
    url "https://github.com/rolldown/rolldown.git",
        revision: "9704b565076baf57b3703c98ebde973855506a68"
    version "9704b565076baf57b3703c98ebde973855506a68"

    livecheck do
      url "https://raw.githubusercontent.com/voidzero-dev/vite-plus/refs/tags/v#{LATEST_VERSION}/packages/tools/.upstream-versions.json"
      strategy :json do |json|
        json.dig("rolldown", "hash")
      end
    end
  end

  resource "vite" do
    url "https://github.com/vitejs/vite.git",
        revision: "434e8e9495436a60789f2b588a04a6a24a3d1661"
    version "434e8e9495436a60789f2b588a04a6a24a3d1661"

    livecheck do
      url "https://raw.githubusercontent.com/voidzero-dev/vite-plus/refs/tags/v#{LATEST_VERSION}/packages/tools/.upstream-versions.json"
      strategy :json do |json|
        json.dig("vite", "hash")
      end
    end
  end

  def install
    resource("rolldown").stage buildpath/"rolldown"
    resource("vite").stage buildpath/"vite"

    # Build with Homebrew pnpm. The staged resources pin their own versions too
    %w[package.json rolldown/package.json vite/package.json].each do |file|
      package_json = buildpath/file
      package_json.atomic_write(JSON.pretty_generate(JSON.parse(package_json.read).except("packageManager")))
    end

    # Vite patches only build-time dependencies, which the production deploy below omits
    (buildpath/"pnpm-workspace.yaml").append_lines "allowUnusedPatches: true"

    system "just", "build"
    system "cargo", "install", *std_cargo_args(path: "crates/vp_global_cli")

    system "pnpm", "--filter=vite-plus", "deploy", "--prod", "--legacy", "--no-optional",
           prefix/"node_modules/vite-plus"
    node_modules = prefix/"node_modules/vite-plus/node_modules"
    # Remove incompatible pre-built `bare-*` binaries. Recurse as `deploy --legacy` writes
    # both the legacy `<name>@<version>` and the current `@/<name>/<version>/<hash>` layouts
    os = OS.kernel_name.downcase
    arch = Hardware::CPU.intel? ? "x64" : Hardware::CPU.arch.to_s
    node_modules.glob(".pnpm/**/prebuilds/*")
                .each { |dir| rm_r(dir) if dir.basename.to_s != "#{os}-#{arch}" }
    rm_r node_modules.glob(".pnpm/**/node_modules/fsevents")

    # Symlink vp to vpr and vpx. These are detected at runtime by argv[0]
    bin.install_symlink bin/"vp" => "vpr"
    bin.install_symlink bin/"vp" => "vpx"

    # Generate shell completions, vp uses clap but with a custom env var so we can't use our helper
    (bash_completion/"vp").write Utils.safe_popen_read({ "VP_COMPLETE" => "bash" }, bin/"vp")
    (fish_completion/"vp.fish").write Utils.safe_popen_read({ "VP_COMPLETE" => "fish" }, bin/"vp")
    (zsh_completion/"_vp").write Utils.safe_popen_read({ "VP_COMPLETE" => "zsh" }, bin/"vp")
  end

  test do
    ENV["VP_HOME"] = testpath/"vp-home"
    ENV["VP_NODE_MANAGER"] = "no"
    ENV["VP_PM_MANAGER"] = "no"
    assert_match version.to_s, shell_output("#{bin}/vp --version")
    refute_path_exists bin/".vp-setup-complete"
    refute_path_exists testpath/"vp-home/current"
    assert_path_exists testpath/"vp-home/self-setup"
    output = shell_output("#{bin}/vp --version 2>&1")
    assert_match version.to_s, output
    refute_match "Vite+ setup complete", output

    ENV.prepend_path "PATH", testpath/"vp-home/bin"
    output = shell_output("#{bin}/vp env doctor node 2>&1")
    assert_match(/CLI source\s+Homebrew/, output)
    assert_match(/CLI binary\s+/, output)
    assert_match(/Shim dir\s+/, output)

    output = shell_output("#{bin}/vp upgrade --force 2>&1", 1)
    assert_match "brew upgrade vite-plus", output
    assert_match "brew outdated vite-plus", shell_output("#{bin}/vp upgrade --check 2>&1")
    refute_path_exists testpath/"vp-home/current"

    # `vp` calls `tcsetattr` on a tty stdin, which stops it with SIGTTOU on the test PTY
    system "#{bin}/vp create vite:application --no-interactive --directory test-app < /dev/null"
    assert_path_exists testpath/"test-app/package.json"

    cd testpath/"test-app" do
      output = shell_output("#{bin}/vp fmt < /dev/null")
      assert_match "Finished", output
    end

    output = shell_output("#{bin}/vp implode --yes 2>&1")
    assert_match "brew uninstall vite-plus", output
    assert_match "hash -r", output
    refute_path_exists testpath/"vp-home"
    assert_path_exists bin/"vp"
  end
end

__END__
diff --git a/crates/vp_global_cli/src/commands/env/setup.rs b/crates/vp_global_cli/src/commands/env/setup.rs
index e98b736bc..621f83d68 100644
--- a/crates/vp_global_cli/src/commands/env/setup.rs
+++ b/crates/vp_global_cli/src/commands/env/setup.rs
@@ -30,6 +30,9 @@ use crate::{
     help,
 };

+#[cfg(unix)]
+mod unix;
+
 /// Shells that get a generated `<CONFIG>/env.*` setup script.
 #[derive(Clone, Copy, Debug)]
 enum EnvShell {
@@ -292,16 +295,16 @@ async fn setup_vp_wrapper(
 pub(crate) async fn resolve_unix_vp_shim_target(
     current_exe: &std::path::Path,
 ) -> Result<std::path::PathBuf, Error> {
+    let current_exe_canon = tokio::fs::canonicalize(current_exe).await.ok();
     let current_vp = crate::commands::global::install::package_shim_target();
-    if tokio::fs::try_exists(&current_vp).await.unwrap_or(false) {
-        let current_vp_canon = tokio::fs::canonicalize(&current_vp).await.ok();
-        let current_exe_canon = tokio::fs::canonicalize(current_exe).await.ok();
-        if current_vp_canon.is_some() && current_vp_canon == current_exe_canon {
-            return Ok(current_vp.as_path().to_path_buf());
-        }
+    if let Some(binary) = &current_exe_canon
+        && tokio::fs::canonicalize(&current_vp).await.is_ok_and(|target| target == *binary)
+    {
+        return Ok(current_vp.as_path().to_path_buf());
     }

-    Ok(current_exe.to_path_buf())
+    let binary = current_exe_canon.unwrap_or_else(|| current_exe.to_path_buf());
+    Ok(unix::external_shim_target(current_exe).unwrap_or(binary))
 }

 /// Create a single default tool shim.
diff --git a/crates/vp_global_cli/src/commands/env/setup/unix.rs b/crates/vp_global_cli/src/commands/env/setup/unix.rs
new file mode 100644
index 000000000..097f7ae16
--- /dev/null
+++ b/crates/vp_global_cli/src/commands/env/setup/unix.rs
@@ -0,0 +1,108 @@
+//! Keep external shims linked through the package manager's public entrypoint.
+
+use std::path::{Path, PathBuf};
+
+use vp_shared::EnvConfig;
+
+pub(super) fn external_shim_target(binary: &Path) -> Option<PathBuf> {
+    let canonical = std::fs::canonicalize(binary).ok()?;
+    let env = EnvConfig::get();
+    let bin = env.dirs.bin.as_path();
+    let cwd = vt_path::current_dir().ok()?;
+    let path = std::env::var_os("PATH").unwrap_or_default();
+    let mut candidates: Vec<_> = std::env::split_paths(&path).map(|dir| dir.join("vp")).collect();
+    // An explicit invocation need not be on PATH. vpx/vpr use the sibling vp.
+    if let Some(invoked) = std::env::args_os().next().map(PathBuf::from)
+        && let Some(parent) = invoked.parent().filter(|parent| !parent.as_os_str().is_empty())
+    {
+        candidates.push(parent.join("vp"));
+    }
+    // Retain a previously selected entrypoint when only the user shims are on PATH.
+    if let Ok(target) = std::fs::read_link(bin.join("vp")) {
+        candidates.push(bin.join(target));
+    }
+    // Preserve the supplied path when it is itself an external entrypoint.
+    candidates.push(binary.to_path_buf());
+    candidates.into_iter().map(|path| cwd.as_path().join(path)).find(|candidate| {
+        candidate != &canonical
+            && std::fs::canonicalize(candidate).is_ok_and(|target| target == canonical)
+            && !passes_through_shims(candidate, bin)
+    })
+}
+
+// Canonical equality alone would accept aliases back to our own vp/node shims,
+// creating a cycle as soon as setup replaces them. Check every link in the chain.
+fn passes_through_shims(candidate: &Path, bin: &Path) -> bool {
+    let bin = std::fs::canonicalize(bin).unwrap_or_else(|_| bin.to_path_buf());
+    let mut path = candidate.to_path_buf();
+    for _ in 0..40 {
+        let Some(parent) = path.parent() else { return true };
+        if std::fs::canonicalize(parent).is_ok_and(|parent| parent.starts_with(&bin)) {
+            return true;
+        }
+        match std::fs::read_link(&path) {
+            Ok(target) => path = parent.join(target),
+            Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => return false,
+            Err(_) => return true,
+        }
+    }
+    true
+}
+
+#[cfg(test)]
+mod tests {
+    use std::os::unix::fs::symlink;
+
+    use super::*;
+
+    #[test]
+    fn prefers_public_entrypoint_and_keeps_it_without_path() {
+        EnvConfig::scoped(|env| {
+            let root = tempfile::tempdir().unwrap();
+            let binary = root.path().join("package/vp");
+            let public = root.path().join("bin/vp");
+            std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
+            std::fs::create_dir_all(public.parent().unwrap()).unwrap();
+            std::fs::create_dir_all(&env.dirs.bin).unwrap();
+            std::fs::write(&binary, b"vp").unwrap();
+            let binary = std::fs::canonicalize(binary).unwrap();
+            symlink("../package/vp", &public).unwrap();
+            symlink(&binary, env.dirs.bin.join("vp")).unwrap();
+            let path =
+                std::env::join_paths([env.dirs.bin.as_path(), public.parent().unwrap()]).unwrap();
+            EnvConfig::with_vars([("PATH", Some(path))], |_| {
+                assert_eq!(external_shim_target(&binary), Some(public.clone()));
+            });
+            std::fs::remove_file(env.dirs.bin.join("vp")).unwrap();
+            symlink(&public, env.dirs.bin.join("vp")).unwrap();
+            EnvConfig::with_vars([("PATH", None::<&str>)], |_| {
+                assert_eq!(external_shim_target(&binary), Some(public));
+            });
+        });
+    }
+
+    #[test]
+    fn rejects_aliases_through_user_shims_and_unrelated_binaries() {
+        EnvConfig::scoped(|env| {
+            let root = tempfile::tempdir().unwrap();
+            let binary = root.path().join("vp");
+            let alias = root.path().join("alias");
+            let foreign = root.path().join("foreign");
+            std::fs::create_dir_all(&alias).unwrap();
+            std::fs::create_dir_all(&foreign).unwrap();
+            std::fs::create_dir_all(&env.dirs.bin).unwrap();
+            std::fs::write(&binary, b"vp").unwrap();
+            let binary = std::fs::canonicalize(binary).unwrap();
+            std::fs::write(foreign.join("vp"), b"another vp").unwrap();
+            symlink(&binary, env.dirs.bin.join("node")).unwrap();
+            symlink(env.dirs.bin.join("node"), alias.join("vp")).unwrap();
+            let directory_alias = root.path().join("directory-alias");
+            symlink(&env.dirs.bin, &directory_alias).unwrap();
+            symlink(&binary, env.dirs.bin.join("vp")).unwrap();
+            let path = std::env::join_paths([alias, directory_alias, foreign]).unwrap();
+            EnvConfig::with_vars([("PATH", Some(path))], |_| {
+                assert_eq!(external_shim_target(&binary), None);
+            });
+        });
+    }
+}
diff --git a/crates/vp_global_cli/src/commands/implode.rs b/crates/vp_global_cli/src/commands/implode.rs
index 0b3992c84..378cc0c58 100644
--- a/crates/vp_global_cli/src/commands/implode.rs
+++ b/crates/vp_global_cli/src/commands/implode.rs
@@ -53,6 +53,7 @@ fn lexical_path(path: &Path) -> PathBuf {
 pub fn execute(yes: bool) -> Result<ExitStatus, Error> {
     let env_config = vp_shared::EnvConfig::get();
     let dirs = &env_config.dirs;
+    let homebrew = crate::homebrew::owns_current_exe();

     // Build a unique set of Vite+-owned roots. In a single-root layout, data,
     // config, and state use the same directory. Cache is inside that directory.
@@ -78,7 +79,12 @@ pub fn execute(yes: bool) -> Result<ExitStatus, Error> {
     }

     if !delete_set.iter().any(|root| root.as_path().exists()) {
-        output::info("vite-plus is not installed. No installation directory exists.");
+        if homebrew {
+            output::info("No Vite+-managed data directories exist.");
+            print_homebrew_uninstall_notice();
+        } else {
+            output::info("vite-plus is not installed. No installation directory exists.");
+        }
         return Ok(exit_status(0));
     }

@@ -134,11 +140,23 @@ pub fn execute(yes: bool) -> Result<ExitStatus, Error> {

     output::raw("");
     output::success("Vite+ removed its managed files and shell entries from your system.");
+    if homebrew {
+        print_homebrew_uninstall_notice();
+    }
     output::note("Restart your terminal to apply shell changes.");

     Ok(exit_status(0))
 }

+fn print_homebrew_uninstall_notice() {
+    output::note(
+        "The Homebrew package remains installed. Run `brew uninstall vite-plus` to remove it.",
+    );
+    output::note(
+        "To run `vp` again, restart your terminal or run `hash -r` in Bash. The remaining Homebrew package will start setup again.",
+    );
+}
+
 /// Remove the shim files vite-plus owns from the bin directory.
 ///
 /// Do not remove the bin directory directly because a bin from an explicit
@@ -311,7 +329,13 @@ fn confirm_implode(
         ));
     }

-    output::warn("This will completely remove vite-plus from your system!");
+    if crate::homebrew::owns_current_exe() {
+        output::warn(
+            "This will remove Vite+-managed data, shims, and shell entries. The Homebrew package will remain installed.",
+        );
+    } else {
+        output::warn("This will completely remove vite-plus from your system!");
+    }
     output::raw("");
     output::raw("  Directories to remove:");
     for root in delete_set {
diff --git a/crates/vp_global_cli/src/commands/upgrade/mod.rs b/crates/vp_global_cli/src/commands/upgrade/mod.rs
index 758de45d6..1fa8741fb 100644
--- a/crates/vp_global_cli/src/commands/upgrade/mod.rs
+++ b/crates/vp_global_cli/src/commands/upgrade/mod.rs
@@ -41,6 +41,20 @@ pub async fn execute(options: UpgradeOptions) -> Result<ExitStatus, Error> {
         return Ok(ExitStatus::default());
     }

+    if crate::homebrew::owns_current_exe() {
+        if options.check && !options.rollback {
+            if !options.silent {
+                output::info(
+                    "Homebrew manages this installation. Run `brew outdated vite-plus` to check for updates.",
+                );
+            }
+            return Ok(ExitStatus::default());
+        }
+        return Err(Error::Upgrade(
+            "Homebrew manages this installation. Run `brew upgrade vite-plus` to update it.".into(),
+        ));
+    }
+
     let config = vp_shared::EnvConfig::get();
     let install_dir = &config.dirs.data;

diff --git a/crates/vp_global_cli/src/homebrew.rs b/crates/vp_global_cli/src/homebrew.rs
new file mode 100644
index 000000000..efbac3313
--- /dev/null
+++ b/crates/vp_global_cli/src/homebrew.rs
@@ -0,0 +1,66 @@
+//! Identify Homebrew ownership without requiring `brew` on PATH or a fixed prefix.
+
+use std::{path::Path, sync::OnceLock};
+
+pub(crate) fn owns_current_exe() -> bool {
+    static HOMEBREW: OnceLock<bool> = OnceLock::new();
+    *HOMEBREW.get_or_init(|| std::env::current_exe().is_ok_and(|binary| owns_binary(&binary)))
+}
+
+fn owns_binary(binary: &Path) -> bool {
+    // Resolve both Homebrew's public entrypoint and Vite+'s generated shims.
+    let Ok(binary) = std::fs::canonicalize(binary) else { return false };
+    let Some(bin) = binary.parent().filter(|bin| bin.file_name().is_some_and(|name| name == "bin"))
+    else {
+        return false;
+    };
+    let Some(prefix) = bin.parent() else { return false };
+    let Ok(data) = std::fs::read(prefix.join("INSTALL_RECEIPT.json")) else { return false };
+    let Ok(receipt) = serde_json::from_slice::<serde_json::Value>(&data) else { return false };
+    receipt
+        .get("homebrew_version")
+        .and_then(serde_json::Value::as_str)
+        .is_some_and(|version| !version.is_empty())
+}
+
+#[cfg(test)]
+mod tests {
+    use super::*;
+
+    #[test]
+    fn detects_receipt_under_custom_prefix() {
+        let temp = tempfile::tempdir().unwrap();
+        let prefix = temp.path().join("custom-cellar/vite-plus/0.3.2");
+        let binary = prefix.join("bin/vp");
+        std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
+        std::fs::write(&binary, "vp").unwrap();
+        assert!(!owns_binary(&binary));
+
+        let receipt = prefix.join("INSTALL_RECEIPT.json");
+        for invalid in
+            ["not json", "{}", r#"{"homebrew_version":null}"#, r#"{"homebrew_version":""}"#]
+        {
+            std::fs::write(&receipt, invalid).unwrap();
+            assert!(!owns_binary(&binary));
+        }
+        std::fs::write(receipt, r#"{"homebrew_version":"7.0.2"}"#).unwrap();
+        assert!(owns_binary(&binary));
+
+        // A separate managed installation stays independent of Homebrew.
+        let managed = temp.path().join("managed/0.3.2/bin/vp");
+        std::fs::create_dir_all(managed.parent().unwrap()).unwrap();
+        std::fs::copy(&binary, &managed).unwrap();
+        assert!(!owns_binary(&managed));
+        assert!(!owns_binary(&prefix.join("missing/bin/vp")));
+
+        #[cfg(unix)]
+        {
+            let public = temp.path().join("public-vp");
+            let shim = temp.path().join("shim-vp");
+            std::os::unix::fs::symlink(&binary, &public).unwrap();
+            std::os::unix::fs::symlink(&public, &shim).unwrap();
+            assert!(owns_binary(&public));
+            assert!(owns_binary(&shim));
+        }
+    }
+}
diff --git a/crates/vp_global_cli/src/main.rs b/crates/vp_global_cli/src/main.rs
index 5f4cb4d34..292791805 100644
--- a/crates/vp_global_cli/src/main.rs
+++ b/crates/vp_global_cli/src/main.rs
@@ -18,6 +18,7 @@ mod command_picker;
 mod commands;
 mod error;
 mod help;
+mod homebrew;
 mod js_executor;
 mod self_setup;
 mod shim;
diff --git a/crates/vp_global_cli/src/self_setup.rs b/crates/vp_global_cli/src/self_setup.rs
index 460292591..050d5655e 100644
--- a/crates/vp_global_cli/src/self_setup.rs
+++ b/crates/vp_global_cli/src/self_setup.rs
@@ -1,5 +1,6 @@
 //! First-start installation followed by command execution through the deployed binary.

+mod external;
 mod shell;

 use std::{path::Path, process::ExitCode};
@@ -39,22 +40,55 @@ pub(crate) async fn maybe_run() -> Result<Option<ExitCode>, Error> {
     }

     vp_shared::validate_vp_dir_env().map_err(|error| Error::Other(error.to_string().into()))?;
+    let data = normalize_target(&EnvConfig::get().dirs.data)?;
+    let external = if dunce::simplified(&binary).starts_with(dunce::simplified(data.as_path())) {
+        None
+    } else {
+        Some(external::SetupState::new(&binary, local_install_version().as_deref())?)
+    };
+    let bundled = external.is_some() && has_bundled_package(&binary);
+    // Installers explicitly request setup, including same-version reinstalls.
+    if shell.is_none()
+        && std::env::var_os(env_vars::VP_SELF_SETUP_REPLACE_EXISTING).is_none()
+        && let Some(state) = &external
+        && let Some(installed_binary) = state.completed_binary(bundled).await?
+    {
+        if installed_binary.as_path() == binary {
+            return Ok(None);
+        }
+        return execute_installed(&installed_binary, false);
+    }
     // Setup diagnostics must not pollute the original command's machine-readable stdout.
     output::route_user_output_to_stderr();
-    let installed_binary = run(&binary).await?;
+    let installed_binary = run(&binary, bundled).await?;
+    if let Some(state) = external {
+        state.save(&installed_binary).await?;
+    }
+    output::success("Vite+ setup complete.");
     if let Some(shell) = shell.as_deref() {
         print_shell_result(shell);
         return Ok(Some(ExitCode::SUCCESS));
     }
+    execute_installed(&installed_binary, true)
+}
+
+fn execute_installed(
+    binary: &AbsolutePath,
+    just_installed: bool,
+) -> Result<Option<ExitCode>, Error> {
     let mut args = std::env::args_os();
     let argv0 = args.next();
     let shim_tool =
         argv0.as_deref().and_then(|name| name.to_str()).and_then(crate::shim::detect_shim_tool);
-    if args.len() == 0 && shim_tool.is_none() && std::env::var_os("VP_COMPLETE").is_none() {
+    if just_installed
+        && args.len() == 0
+        && shim_tool.is_none()
+        && std::env::var_os("VP_COMPLETE").is_none()
+    {
         return Ok(Some(ExitCode::SUCCESS));
     }
     // Re-enter through the marked installation, inheriting cwd, environment and stdio.
-    let mut command = std::process::Command::new(installed_binary.as_path());
+    let mut command = std::process::Command::new(binary.as_path());
     command.args(args);
     #[cfg(unix)]
     {
@@ -75,6 +109,21 @@ pub(crate) async fn maybe_run() -> Result<Option<ExitCode>, Error> {
     }
 }

+fn has_bundled_package(binary: &Path) -> bool {
+    let Some(prefix) = binary.parent().and_then(Path::parent) else { return false };
+    let package = prefix.join("node_modules/vite-plus");
+    // Unix shims can target an external binary; Windows trampolines need the managed layout.
+    cfg!(unix) && package.join("package.json").is_file() && package.join("dist/bin.js").is_file()
+}
+
+fn local_install_version() -> Option<String> {
+    let skip_deps = std::env::var_os("VP_SKIP_DEPS_INSTALL")?;
+    if skip_deps.is_empty() {
+        return None;
+    }
+    std::env::var("VP_VERSION").ok()
+}
+
 // Only successful setup emits executable output; logs use stderr in this mode.
 fn print_shell_result(shell: &str) {
     let dirs = &EnvConfig::get().dirs;
@@ -98,11 +147,13 @@ fn print_shell_result(shell: &str) {
 }

 /// Setup Vite+ for the first run
-async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
+async fn run(source: &Path, bundled: bool) -> Result<AbsolutePathBuf, Error> {
     let env = EnvConfig::get();
     let dirs = &env.dirs;
     let active_binary = dirs.data.join("current").join("bin").join(VP_BINARY_NAME);
     let in_place = same_file::is_same_file(source, active_binary.as_path()).unwrap_or(false);
+    // External package managers own their payload. Only set up the user's config and shims.
+    let deploy = !in_place && !bundled;
     #[cfg(windows)]
     if !in_place
         && ["vp.exe", "vpx.exe", "vpr.exe"]
@@ -119,12 +170,17 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
             "Installation cancelled; existing Vite+ commands were kept.".into(),
         ));
     }
-    let previous_install = previous_install()?;
+    let previous_install = if deploy { previous_install()? } else { None };
     let node_override = manager_mode("VP_NODE_MANAGER");
+    // A package upgrade can change the executable path or expire its receipt.
+    // Preferences belong to the user, not to that particular binary.
+    let configured = bundled && config::get_config_path()?.as_path().is_file();
     // A supplied Node choice skips the combined prompt; upgrades preserve all saved choices.
-    let default_mode =
-        if in_place || node_override.is_some() { None } else { management_default()? };
-    let node_mode = if in_place { None } else { node_override.or(default_mode) };
+    let default_mode = if in_place || configured || node_override.is_some() {
+        None
+    } else {
+        management_default()?
+    };
     let version = env!("CARGO_PKG_VERSION");
     let registry = std::env::var(env_vars::NPM_CONFIG_REGISTRY_UPPER)
         .or_else(|_| std::env::var(env_vars::NPM_CONFIG_REGISTRY))
@@ -138,7 +194,7 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
     let registry = registry.as_deref();
     // The local bootstrap provisions JS dependencies itself after this invocation.
     let skip_deps = std::env::var_os("VP_SKIP_DEPS_INSTALL").is_some_and(|value| !value.is_empty());
-    let local_version = skip_deps.then(|| std::env::var("VP_VERSION").ok()).flatten();
+    let local_version = local_install_version();
     let install_version = local_version.as_deref().unwrap_or(version);
     if !in_place
         && (install_version.is_empty()
@@ -153,22 +209,30 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {

     // 1. Prepare the payload before activating it. Upgrade has already done this in the in-place case.
     let previous_version = install::read_current_version(&dirs.data).await;
-    let version_dir = if in_place {
+    let version_dir = if deploy {
+        let name =
+            install::target_install_dir_name(install_version, previous_version.as_deref(), true);
+        dirs.data.join(name)
+    } else {
         AbsolutePathBuf::new(
             source.parent().and_then(Path::parent).ok_or(Error::CliBinaryNotFound)?.to_path_buf(),
         )
         .ok_or(Error::CliBinaryNotFound)?
+    };
+    let binary = if bundled {
+        AbsolutePathBuf::new(source.to_path_buf()).ok_or(Error::CliBinaryNotFound)?
     } else {
-        let name =
-            install::target_install_dir_name(install_version, previous_version.as_deref(), true);
-        dirs.data.join(name)
+        version_dir.join("bin").join(VP_BINARY_NAME)
     };
-    let binary = version_dir.join("bin").join(VP_BINARY_NAME);
-    if !in_place {
+    if deploy {
         tokio::fs::create_dir_all(version_dir.join("bin")).await?;
         install::clear_self_setup_marker(&version_dir).await?;
         if !same_file::is_same_file(source, binary.as_path()).unwrap_or(false) {
-            tokio::fs::copy(source, &binary).await?;
+            // A failed install can leave a read-only copy from a package manager.
+            // Replace it atomically instead of opening it for writing on retry.
+            let temporary = tempfile::NamedTempFile::new_in(version_dir.join("bin"))?;
+            tokio::fs::copy(source, temporary.path()).await?;
+            temporary.persist(binary.as_path()).map_err(|error| error.error)?;
         }
     }
     if !version_dir.join("node_modules/vite-plus/package.json").as_path().is_file() {
@@ -179,7 +243,7 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
         }
     }
     #[cfg(windows)]
-    if !version_dir.join("bin/vp-shim.exe").as_path().is_file() {
+    if !bundled && !version_dir.join("bin/vp-shim.exe").as_path().is_file() {
         let sibling = source.with_file_name("vp-shim.exe");
         if sibling.is_file() {
             tokio::fs::copy(sibling, version_dir.join("bin/vp-shim.exe")).await?;
@@ -205,7 +269,9 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {

     if !in_place {
         // Prepare the payload first, then let the old uninstaller clean its shell entries before writing ours.
-        remove_previous_install(previous_install.as_deref()).await?;
+        if deploy {
+            remove_previous_install(previous_install.as_deref()).await?;
+        }
         if std::env::var(env_vars::VP_SELF_SETUP_NO_MODIFY_PATH).as_deref() != Ok("1") {
             if let Err(error) = shell::configure().await {
                 output::warn(&format!(
@@ -214,10 +280,8 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
                 ));
             }
         }
-    }
-    if !in_place {
         let mut settings = config::load_config().await?;
-        if let Some(mode) = node_mode {
+        if let Some(mode) = node_override.or(default_mode) {
             settings.node_shim_mode = mode;
         }
         let pm_mode = manager_mode("VP_PM_MANAGER").or(default_mode);
@@ -235,7 +299,7 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
     }

     // 2. Activate a standalone download; an upgrade hook must not overwrite rollback history.
-    if !in_place {
+    if deploy {
         install::save_previous_version(&dirs.data).await?;
         let name = version_dir
             .as_path()
@@ -251,7 +315,7 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
     // VpDirs::bin is private by default, so replacing its shims leaves system-first tools elsewhere on PATH intact.
     // Users explicitly pointing VpDirs::bin at a shared directory accept replacement of conflicting entries there.
     setup::execute_for_binary(binary.as_path(), true, true, false).await?;
-    if !in_place {
+    if deploy {
         let name = version_dir
             .as_path()
             .file_name()
@@ -269,8 +333,9 @@ async fn run(source: &Path) -> Result<AbsolutePathBuf, Error> {
     }

     // A failure above leaves the marker absent so a later launch can retry.
-    tokio::fs::write(version_dir.join("bin").join(SELF_SETUP_MARKER), b"").await?;
-    output::success("Vite+ setup complete.");
+    if !bundled {
+        tokio::fs::write(version_dir.join("bin").join(SELF_SETUP_MARKER), b"").await?;
+    }
     Ok(binary)
 }

diff --git a/crates/vp_global_cli/src/self_setup/external.rs b/crates/vp_global_cli/src/self_setup/external.rs
new file mode 100644
index 000000000..0f1c2ff64
--- /dev/null
+++ b/crates/vp_global_cli/src/self_setup/external.rs
@@ -0,0 +1,159 @@
+//! Per-user setup receipts for binaries owned by an external installer.
+
+use std::{
+    hash::{Hash, Hasher},
+    path::{Path, PathBuf},
+    time::SystemTime,
+};
+
+use serde::{Deserialize, Serialize};
+use vp_setup::SELF_SETUP_MARKER;
+use vp_shared::EnvConfig;
+use vt_path::{AbsolutePath, AbsolutePathBuf};
+
+use crate::error::Error;
+
+#[derive(Deserialize, Serialize, PartialEq, Eq)]
+struct Source {
+    path: PathBuf,
+    version: String,
+    modified: SystemTime,
+    len: u64,
+}
+
+#[derive(Deserialize, Serialize)]
+struct Receipt {
+    source: Source,
+    binary: PathBuf,
+}
+
+pub(super) struct SetupState {
+    source: Source,
+    path: AbsolutePathBuf,
+}
+
+impl SetupState {
+    pub(super) fn new(binary: &Path, local_version: Option<&str>) -> Result<Self, Error> {
+        let metadata = std::fs::metadata(binary)?;
+        let mut hash = rustc_hash::FxHasher::default();
+        binary.hash(&mut hash);
+        Ok(Self {
+            source: Source {
+                path: binary.to_path_buf(),
+                version: local_version.unwrap_or(env!("CARGO_PKG_VERSION")).to_string(),
+                modified: metadata.modified()?,
+                len: metadata.len(),
+            },
+            path: EnvConfig::get()
+                .dirs
+                .state
+                .join("self-setup")
+                .join(format!("{:016x}.json", hash.finish())),
+        })
+    }
+
+    pub(super) async fn completed_binary(
+        &self,
+        bundled: bool,
+    ) -> Result<Option<AbsolutePathBuf>, Error> {
+        let data = match tokio::fs::read(&self.path).await {
+            Ok(data) => data,
+            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
+            Err(error) => return Err(error.into()),
+        };
+        // An interrupted receipt write must allow setup to retry.
+        let Ok(receipt) = serde_json::from_slice::<Receipt>(&data) else { return Ok(None) };
+        if receipt.source != self.source || !receipt.binary.is_file() {
+            return Ok(None);
+        }
+        let complete = if bundled {
+            receipt.binary == self.source.path
+        } else {
+            receipt.binary != self.source.path
+                && receipt.binary.parent().is_some_and(|bin| bin.join(SELF_SETUP_MARKER).is_file())
+        };
+        if !complete {
+            return Ok(None);
+        }
+        Ok(AbsolutePathBuf::new(receipt.binary))
+    }
+
+    pub(super) async fn save(self, binary: &AbsolutePath) -> Result<(), Error> {
+        tokio::fs::create_dir_all(self.path.parent().ok_or(Error::CliBinaryNotFound)?).await?;
+        let receipt = Receipt { source: self.source, binary: binary.as_path().to_path_buf() };
+        tokio::fs::write(&self.path, serde_json::to_vec(&receipt)?).await?;
+        Ok(())
+    }
+}
+
+#[cfg(test)]
+mod tests {
+    use super::*;
+
+    #[tokio::test]
+    async fn bundled_receipt_is_per_user_and_invalidated_when_source_changes() {
+        EnvConfig::scoped_async(|env| async move {
+            let binary = env.dirs.data.join("external/bin/vp");
+            tokio::fs::create_dir_all(binary.parent().unwrap()).await.unwrap();
+            tokio::fs::write(&binary, b"vp").await.unwrap();
+            let state = SetupState::new(binary.as_path(), None).unwrap();
+            assert!(state.path.as_path().starts_with(env.dirs.state.as_path()));
+            assert!(state.completed_binary(true).await.unwrap().is_none());
+            state.save(&binary).await.unwrap();
+
+            let state = SetupState::new(binary.as_path(), None).unwrap();
+            assert_eq!(state.completed_binary(true).await.unwrap(), Some(binary.clone()));
+            assert!(state.completed_binary(false).await.unwrap().is_none());
+            assert!(!binary.parent().unwrap().join(SELF_SETUP_MARKER).as_path().exists());
+
+            tokio::fs::write(&binary, b"new vp build").await.unwrap();
+            let state = SetupState::new(binary.as_path(), None).unwrap();
+            assert!(state.completed_binary(true).await.unwrap().is_none());
+        })
+        .await;
+    }
+
+    #[tokio::test]
+    async fn standalone_receipt_requires_a_marked_deployed_binary() {
+        EnvConfig::scoped_async(|env| async move {
+            let source = env.dirs.data.join("vp");
+            let binary = env.dirs.data.join("version/bin/vp");
+            tokio::fs::write(&source, b"vp").await.unwrap();
+            tokio::fs::create_dir_all(binary.parent().unwrap()).await.unwrap();
+            tokio::fs::write(&binary, b"vp").await.unwrap();
+            SetupState::new(source.as_path(), None).unwrap().save(&binary).await.unwrap();
+            let state = SetupState::new(source.as_path(), None).unwrap();
+            assert!(state.completed_binary(false).await.unwrap().is_none());
+
+            let marker = binary.parent().unwrap().join(SELF_SETUP_MARKER);
+            tokio::fs::write(&marker, b"").await.unwrap();
+            assert_eq!(state.completed_binary(false).await.unwrap(), Some(binary.clone()));
+            // A package manager can add a bundled CLI after a bare-binary install.
+            assert!(state.completed_binary(true).await.unwrap().is_none());
+
+            // Upgrade clears the marker; cleanup or implode can remove the target entirely.
+            tokio::fs::remove_file(&marker).await.unwrap();
+            assert!(state.completed_binary(false).await.unwrap().is_none());
+            tokio::fs::write(&marker, b"").await.unwrap();
+            tokio::fs::remove_file(&binary).await.unwrap();
+            assert!(state.completed_binary(false).await.unwrap().is_none());
+        })
+        .await;
+    }
+
+    #[tokio::test]
+    async fn changed_version_or_incomplete_receipt_retries_setup() {
+        EnvConfig::scoped_async(|env| async move {
+            let binary = env.dirs.data.join("vp");
+            tokio::fs::write(&binary, b"vp").await.unwrap();
+            SetupState::new(binary.as_path(), Some("first")).unwrap().save(&binary).await.unwrap();
+            let state = SetupState::new(binary.as_path(), Some("second")).unwrap();
+            assert!(state.completed_binary(true).await.unwrap().is_none());
+
+            tokio::fs::write(&state.path, b"{\"source\":").await.unwrap();
+            let state = SetupState::new(binary.as_path(), Some("first")).unwrap();
+            assert!(state.completed_binary(true).await.unwrap().is_none());
+        })
+        .await;
+    }
+}
diff --git a/crates/vp_global_cli/src/upgrade_check.rs b/crates/vp_global_cli/src/upgrade_check.rs
index 1fe991c28..98b641c2e 100644
--- a/crates/vp_global_cli/src/upgrade_check.rs
+++ b/crates/vp_global_cli/src/upgrade_check.rs
@@ -139,6 +139,7 @@ fn checks_disabled() -> bool {
     std::env::var_os("VP_NO_UPDATE_CHECK").is_some()
         || vp_shared::EnvConfig::get().is_ci
         || std::env::var_os("VP_CLI_TEST").is_some()
+        || crate::homebrew::owns_current_exe()
 }

 fn should_check(cache: Option<&UpgradeCheckCache>, current_version: &str, now: u64) -> bool {
diff --git a/crates/vp_global_cli/src/commands/env/doctor.rs b/crates/vp_global_cli/src/commands/env/doctor.rs
--- a/crates/vp_global_cli/src/commands/env/doctor.rs
+++ b/crates/vp_global_cli/src/commands/env/doctor.rs
@@ -53,7 +53,7 @@
 /// Use `" "` for informational lines with no status.
 fn print_check(status: &str, key: &str, value: &str) {
     if status.trim().is_empty() {
-        println!("  {key:<KEY_WIDTH$}{value}");
+        println!("    {key:<KEY_WIDTH$}{value}");
     } else if key.trim().is_empty() {
         println!("  {status} {value}");
     } else {
@@ -91,6 +91,12 @@

     // Section: Installation
     println!("{}", "Installation".bold());
+    if crate::homebrew::owns_current_exe() {
+        print_check(" ", "CLI source", "Homebrew");
+        if let Ok(binary) = std::env::current_exe().and_then(std::fs::canonicalize) {
+            print_check(" ", "CLI binary", &abbreviate_home(&binary.display().to_string()));
+        }
+    }
     has_errors |= !check_dirs().await;
     has_errors |= !check_shims(scope).await;

@@ -503,6 +509,23 @@
         Err(_) => return false,
     };

+    // The public vp can be on PATH even when the user's shim directory is not.
+    let vp_path = find_in_path("vp");
+    if let Some(path) = &vp_path {
+        print_check(
+            &output::CHECK.green().to_string(),
+            "vp",
+            &abbreviate_home(&path.display().to_string()),
+        );
+    } else {
+        print_check(
+            &output::CROSS.red().to_string(),
+            "vp",
+            &"not in PATH".red().to_string(),
+        );
+        print_hint("Run 'vp env setup' to create the vp shim.");
+    }
+
     let path_var = std::env::var_os("PATH").unwrap_or_default();
     let paths: Vec<_> = std::env::split_paths(&path_var).collect();

@@ -513,9 +536,9 @@
     let bin_display = abbreviate_home(&bin_dir.as_path().display().to_string());

     if bin_in_path {
-        print_check(&output::CHECK.green().to_string(), "vp", "in PATH");
+        print_check(&output::CHECK.green().to_string(), "Shim dir", &bin_display);
     } else {
-        print_check(&output::CROSS.red().to_string(), "vp", &"not in PATH".red().to_string());
+        print_check(&output::CROSS.red().to_string(), "Shim dir", &"not in PATH".red().to_string());
         print_hint(&format!("Expected: {bin_display}"));
         println!();
         print_path_fix(&vp_shared::EnvConfig::get().dirs.config);
@@ -545,7 +568,7 @@
         }
     }

-    true
+    vp_path.is_some()
 }

 /// Find an executable in PATH.
