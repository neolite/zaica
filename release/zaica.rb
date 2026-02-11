class Zaica < Formula
  desc "Zig-based AI coding agent CLI"
  homepage "https://github.com/neolite/zaica"
  version "0.5-alpha"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/neolite/zaica/releases/download/v0.5-alpha/zc-v0.5-alpha-aarch64-macos.tar.gz"
      sha256 "b40db9601eb0f002ac6f78edc3beefdb934442105199a824a4d0ac13a7f6d7e4"
    else
      url "https://github.com/neolite/zaica/releases/download/v0.5-alpha/zc-v0.5-alpha-x86_64-macos.tar.gz"
      sha256 "2ea60d2c04bed238d23538866acd2867ab78516f739d2a6da16697f806c116f7"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/neolite/zaica/releases/download/v0.5-alpha/zc-v0.5-alpha-aarch64-linux.tar.gz"
      sha256 "9a1fffa56e3bf4bbf6a7c76d1ecf51d1528f1604d046e243d9aa546d35a22822"
    else
      url "https://github.com/neolite/zaica/releases/download/v0.5-alpha/zc-v0.5-alpha-x86_64-linux.tar.gz"
      sha256 "efe1aa77b2ff199295fcc3ecc586f6b576598c5abb8fe24f09a509deb8c5f9de"
    end
  end

  def install
    if OS.mac?
      if Hardware::CPU.arm?
        bin.install "zc-aarch64-macos" => "zc"
      else
        bin.install "zc-x86_64-macos" => "zc"
      end
    else
      if Hardware::CPU.arm?
        bin.install "zc-aarch64-linux" => "zc"
      else
        bin.install "zc-x86_64-linux" => "zc"
      end
    end
  end

  test do
    assert_match "zaica", shell_output("#{bin}/zc --help 2>&1", 1)
  end
end
