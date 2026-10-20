class Modelmatrix < Formula
  desc "Menu bar and local dashboard for managing LLM runtimes"
  homepage "https://github.com/Hackstar1337/ModelMatrix"
  # Latest published app code, including Hugging Face and app connections.
  url "https://github.com/Hackstar1337/ModelMatrix/archive/214863ac289c0197a593bd9d61a1d915e134c356.tar.gz"
  version "1.0.0"
  sha256 "b8dff97c7ea26e0d4c705ad1f6d6919eb23f84d1cd519c7bc587ad792c0e0a84"
  license "MIT"

  head "https://github.com/Hackstar1337/ModelMatrix.git", branch: "main"

  depends_on "xcodegen" => :build
  depends_on "python@3.14"
  depends_on macos: :sonoma
  depends_on xcode: ["16.0", :build]

  # The app is stripped and signed by the upstream build script. Do not
  # modify its signed bundle during Homebrew's cleanup.
  skip_clean "ModelMatrix.app"
  preserve_rpath

  def install
    odie "The source archive is missing its prebuilt dashboard" unless (buildpath/"Dashboard/dist/index.html").file?
    odie "The source archive is missing its app icon" unless (buildpath/"Resources/App/ModelMatrix.icns").file?

    # The checked-in dashboard belongs to this exact source snapshot. Reuse
    # it instead of downloading JavaScript dependencies during installation.
    ENV["MODELMATRIX_SKIP_DASHBOARD_BUILD"] = "1"
    ENV["CONFIGURATION"] = "Release"

    # Quick Look uses an out-of-process GUI service which is unsuitable for
    # Homebrew's build sandbox. The source archive already contains the icon.
    inreplace "Scripts/build-xcode-app.sh",
              '"$ROOT_DIR/Scripts/generate-app-icon.sh" >/dev/null',
              '# Homebrew uses the source snapshot\'s checked-in ModelMatrix.icns.'

    system "./Scripts/build-app.sh"
    app = buildpath/"dist/ModelMatrix.app"
    system "./Scripts/verify-embedded-controller.sh", app
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", app
    prefix.install app
    installed_app = prefix/"ModelMatrix.app"
    odie "The installed app executable is missing" unless (installed_app/"Contents/MacOS/ModelMatrix").executable?
    odie "The installed widget is missing" unless (installed_app/"Contents/PlugIns/ModelMatrixWidget.appex").directory?
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", installed_app

    libexec.install "Scripts/modelmatrixctl", "Scripts/controller-endpoint-defaults.sh"
    (bin/"modelmatrixctl").write <<~SH
      #!/bin/bash
      export PATH="#{Formula["python@3.14"].opt_libexec}/bin:$PATH"
      export MODELMATRIX_CONTROLLER_BIN="${MODELMATRIX_CONTROLLER_BIN:-#{opt_prefix}/ModelMatrix.app/Contents/Resources/ModelMatrixController}"
      exec "#{libexec}/modelmatrixctl" "$@"
    SH
    (bin/"modelmatrixctl").chmod 0755

    { "bash" => [bash_completion, "modelmatrixctl"],
      "zsh" => [zsh_completion, "_modelmatrixctl"],
      "fish" => [fish_completion, "modelmatrixctl.fish"] }.each do |shell, (directory, name)|
      completion = buildpath/"modelmatrixctl.#{shell}"
      completion.write Utils.safe_popen_read(bin/"modelmatrixctl", "completions", shell)
      directory.install completion => name
    end

    doc.install "README.md", "CHANGELOG.md", "DASHBOARD.md", "CONNECT_APPS.md", "LICENSE"
    (doc/"licenses").install "Vendor/MenuBarExtraAccess/LICENSE" => "MenuBarExtraAccess-LICENSE"
  end

  def caveats
    <<~EOS
      This is a source build; full Xcode 16 or newer is required, not only Command Line Tools.
      Open the Homebrew-managed app after installation:
        open "#{opt_prefix}/ModelMatrix.app"

      The dashboard is normally http://localhost:7700 after the app starts.
      Installation does not start services, modify profiles, or install models/engines.
      On first launch, ModelMatrix sets up its controller through its normal app workflow.
      Existing model files, profiles and app connections remain in your user folders.
      Do not run the source uninstaller to remove this Homebrew-managed installation.
      Use brew uninstall hackstar1337/modelmatrix/modelmatrix instead.
      An independently installed copy in ~/Applications is not replaced by this formula.
    EOS
  end

  test do
    assert_match "Usage: modelmatrixctl", shell_output("#{bin}/modelmatrixctl help")
    assert_match "connect", shell_output("#{bin}/modelmatrixctl help")
    assert_predicate prefix/"ModelMatrix.app/Contents/MacOS/ModelMatrix", :executable?
    assert_predicate prefix/"ModelMatrix.app/Contents/Resources/ModelMatrixController", :executable?
    assert_path_exists prefix/"ModelMatrix.app/Contents/Resources/Dashboard/index.html"
    assert_path_exists prefix/"ModelMatrix.app/Contents/Resources/RemoteAgent/client_connections.py"
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", prefix/"ModelMatrix.app"
  end
end
