class SecretsBridge < Formula
  desc "Fetch cloud and wallet secrets into local .env, Postman and Bruno files"
  homepage "https://github.com/nuvemlabs/secrets-bridge"
  url "https://github.com/nuvemlabs/secrets-bridge.git",
      tag:      "v1.1.0",
      revision: "d17e8cfd920febeb7ddaa7a198d59f93a706206c"
  license "MIT"
  head "https://github.com/nuvemlabs/secrets-bridge.git", branch: "main"

  depends_on "nuvemlabs/tap/secrets"
  uses_from_macos "python"

  def install
    ENV["SECRETS_BRIDGE_INSTALL_DIR"] = libexec
    ENV["SECRETS_BRIDGE_BIN_DIR"] = bin
    ENV["PREFIX"] = prefix
    system "bash", "install.sh"
    pkgshare.install "examples/.secrets-manifest.yml" => "secrets-manifest.example.yml"
  end

  def caveats
    <<~EOS
      Azure sources need the Azure CLI (brew install azure-cli),
      Bitwarden sources need the Bitwarden CLI (brew install bitwarden-cli).
      An example manifest is in:
        #{opt_pkgshare}/secrets-manifest.example.yml
    EOS
  end

  test do
    assert_match "secrets-bridge v#{version}", shell_output("#{bin}/secrets-bridge --version")
    (testpath/".secrets-manifest.yml").write <<~YAML
      project: brew-test
      environments:
        dev:
          secrets:
            - name: greeting
              value: hello
    YAML
    assert_match "Manifest is valid", shell_output("#{bin}/secrets-bridge validate")
  end
end
