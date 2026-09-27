#!/usr/bin/env bash
# Ubuntu 패키지를 작업 디렉터리에만 추출한다. sudo/시스템 패키지 변경 없음.
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tools_dir=${1:-"$project_root/build/synthesis-tools"}
mkdir -p -- "$tools_dir"
tools_dir=$(cd -- "$tools_dir" && pwd -P)

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
fi
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 || $(dpkg --print-architecture) != amd64 ]]; then
  printf '이 설치 스크립트는 Ubuntu 26.04 amd64(WSL 포함)용입니다. 다른 환경에서는 Yosys, sv2v, nextpnr-ice40, icepack을 직접 설치하세요.\n' >&2
  exit 1
fi
for command_name in apt-get dpkg-deb sha256sum python3 curl; do
  command -v "$command_name" >/dev/null || { printf '필수 명령이 없습니다: %s\n' "$command_name" >&2; exit 1; }
done

archive_keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
[[ -r "$archive_keyring" ]] || { printf 'Ubuntu 저장소 서명 키를 찾을 수 없습니다.\n' >&2; exit 1; }
apt_dir=$tools_dir/apt
install_root=$tools_dir/root
mkdir -p -- "$apt_dir/lists/partial" "$apt_dir/archives/partial" "$install_root" "$tools_dir/bin"
cat > "$apt_dir/sources.list" <<EOF
deb [signed-by=$archive_keyring] http://archive.ubuntu.com/ubuntu/ resolute main universe
deb [signed-by=$archive_keyring] http://archive.ubuntu.com/ubuntu/ resolute-updates main universe
deb [signed-by=$archive_keyring] http://security.ubuntu.com/ubuntu/ resolute-security main universe
EOF
apt_options=(
  -o "Dir::Etc::sourcelist=$apt_dir/sources.list"
  -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=$apt_dir/lists"
  -o "Dir::Cache::archives=$apt_dir/archives"
  -o "APT::Sandbox::User=$(id -un)"
  -o Debug::NoLocking=1
  -o APT::Get::AllowUnauthenticated=false
)
apt-get "${apt_options[@]}" update
rm -f -- "$apt_dir"/archives/*.deb
apt-get "${apt_options[@]}" install --download-only --reinstall -y --no-install-recommends \
  yosys nextpnr-ice40 fpga-icestorm

shopt -s nullglob
packages=("$apt_dir"/archives/*.deb)
(( ${#packages[@]} > 0 )) || { printf '내려받은 패키지가 없습니다.\n' >&2; exit 1; }
rm -rf -- "$install_root"
mkdir -p -- "$install_root"
manifest=$tools_dir/package-manifest.tsv
printf 'package\tversion\tarchitecture\tsha256\n' > "$manifest"
for package_file in "${packages[@]}"; do
  package_name=$(dpkg-deb -f "$package_file" Package)
  package_version=$(dpkg-deb -f "$package_file" Version)
  package_arch=$(dpkg-deb -f "$package_file" Architecture)
  package_hash=$(sha256sum "$package_file")
  printf '%s\t%s\t%s\t%s\n' "$package_name" "$package_version" "$package_arch" "${package_hash%% *}" >> "$manifest"
  case "$package_name" in
    libc6|libc-bin|libc-gconv-modules-extra|locales) continue ;;
  esac
  dpkg-deb -x "$package_file" "$install_root"
done

# 공식 고정 버전: https://github.com/zachjs/sv2v/releases/tag/v0.0.12
sv2v_version=v0.0.12
sv2v_sha256=ff8c9eea5bc029b372fb4953427625cddb7cf7e58c1240623ac9f260818d5a00
sv2v_archive=$tools_dir/sv2v-Linux-$sv2v_version.zip
curl --fail --location --retry 2 \
  "https://github.com/zachjs/sv2v/releases/download/$sv2v_version/sv2v-Linux.zip" \
  -o "$sv2v_archive"
printf '%s  %s\n' "$sv2v_sha256" "$sv2v_archive" | sha256sum --check -
python3 - "$sv2v_archive" "$tools_dir" <<'PY'
from pathlib import Path
import sys
import zipfile

destination = Path(sys.argv[2])
with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in ("sv2v", "LICENSE", "NOTICE", "README.md", "CHANGELOG.md"):
        target = destination / ("bin/sv2v" if name == "sv2v" else f"sv2v/{name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(f"sv2v-Linux/{name}"))
(destination / "bin/sv2v").chmod(0o755)
PY
printf 'sv2v\t%s\tamd64\t%s\n' "$sv2v_version" "$sv2v_sha256" >> "$manifest"

# Ubuntu nextpnr는 /usr/share/nextpnr를 상수 경로로 사용한다. 패키지 원본을
# 유지한 채 로컬 복사본의 경로만 재배치하며 원본/복사본 해시를 기록한다.
cp -- "$project_root/synth/nextpnr_local.py" "$tools_dir/bin/nextpnr-ice40"
chmod +x "$tools_dir/bin/nextpnr-ice40"

printf -v quoted_dir '%q' "$tools_dir"
printf 'export VERILOG_SYNTHESIS_ROOT=%s\n' "$quoted_dir" > "$tools_dir/env.sh"
cat >> "$tools_dir/env.sh" <<'EOF'
export PATH="$VERILOG_SYNTHESIS_ROOT/bin:$VERILOG_SYNTHESIS_ROOT/root/usr/bin:$PATH"
export LD_LIBRARY_PATH="$VERILOG_SYNTHESIS_ROOT/root/usr/lib/x86_64-linux-gnu:$VERILOG_SYNTHESIS_ROOT/root/usr/lib:${LD_LIBRARY_PATH:-}"
export YOSYS_DATDIR="$VERILOG_SYNTHESIS_ROOT/root/usr/share/yosys"
EOF

(
  . "$tools_dir/env.sh"
  yosys -V
  sv2v --version
  nextpnr-ice40 --version
  nextpnr-ice40 --help 2>&1 | python3 -c 'import sys; text = sys.stdin.read(); sys.exit(0 if "--hx8k" in text else "nextpnr가 HX8K 칩 데이터베이스를 읽지 못했습니다")'
)
printf '\n환경 적용: source %q\n패키지 버전/해시: %s\n' "$tools_dir/env.sh" "$manifest"
