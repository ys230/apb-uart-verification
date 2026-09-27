#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
toolchain_dir=${1:-${VERILOG_TOOLCHAIN_DIR:-"$project_root/build/toolchain"}}
mkdir -p -- "$toolchain_dir"
toolchain_dir=$(cd -- "$toolchain_dir" && pwd -P)

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 || $(dpkg --print-architecture) != amd64 ]]; then
  printf '이 설치 스크립트는 Ubuntu 26.04 amd64(WSL 포함)에서 실행해야 합니다.\n' >&2
  exit 1
fi

for command_name in apt-get dpkg-deb sha256sum python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '필수 명령이 없습니다: %s\n' "$command_name" >&2
    exit 1
  fi
done

archive_keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
if [[ ! -r $archive_keyring ]]; then
  printf 'Ubuntu 저장소 서명 키가 없습니다: %s\n' "$archive_keyring" >&2
  exit 1
fi

apt_dir=$toolchain_dir/apt
install_root=$toolchain_dir/root
mkdir -p -- "$apt_dir/lists/partial" "$apt_dir/archives/partial" "$install_root" "$toolchain_dir/bin"

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

printf '서명된 Ubuntu 패키지 목록을 갱신합니다...\n'
apt-get "${apt_options[@]}" update
printf 'Verilator, GNU Make, g++ 및 의존 패키지를 내려받습니다...\n'
# 이전 실행의 패키지와 갱신된 버전이 섞이지 않게 한다.
rm -f -- "$apt_dir"/archives/*.deb
apt-get "${apt_options[@]}" install --download-only -y --no-install-recommends verilator make g++

shopt -s nullglob
packages=("$apt_dir"/archives/*.deb)
if (( ${#packages[@]} == 0 )); then
  printf 'APT에서 내려받은 패키지가 없습니다.\n' >&2
  exit 1
fi

rm -rf -- "$install_root"
mkdir -p -- "$install_root"

# APT가 InRelease 서명을 인증하고 내려받는 .deb 해시를 검증한다.
# 이번 설치에 사용한 패키지 버전과 해시를 정확히 기록한다.
manifest=$toolchain_dir/package-manifest.tsv
printf 'package\tversion\tarchitecture\tsha256\n' > "$manifest"
for package_file in "${packages[@]}"; do
  package_name=$(dpkg-deb -f "$package_file" Package)
  package_version=$(dpkg-deb -f "$package_file" Version)
  package_arch=$(dpkg-deb -f "$package_file" Architecture)
  package_hash=$(sha256sum "$package_file")
  printf '%s\t%s\t%s\t%s\n' "$package_name" "$package_version" "$package_arch" "${package_hash%% *}" >> "$manifest"

  # 호스트 glibc 런타임 파일을 유지한다.
  case "$package_name" in
    libc6|libc-bin|libc-gconv-modules-extra|locales|fonts-lato|fonts-font-awesome|sphinx-rtd-theme-common)
      continue
      ;;
  esac
  dpkg-deb -x "$package_file" "$install_root"
done

# Ubuntu libc 개발용 링커 스크립트가 가리키는 정적 보조 아카이브 경로를
# 추출한 로컬 복사본으로 바꾼다.
python3 - "$install_root/usr/lib/x86_64-linux-gnu/libc.so" "$install_root/usr/lib/x86_64-linux-gnu/libc_nonshared.a" <<'PY'
from pathlib import Path
import sys

linker_script = Path(sys.argv[1])
local_archive = Path(sys.argv[2])
old_path = "/usr/lib/x86_64-linux-gnu/libc_nonshared.a"
contents = linker_script.read_text()
if old_path not in contents and str(local_archive) not in contents:
    raise SystemExit(f"예상하지 못한 libc 링커 스크립트: {linker_script}")
linker_script.write_text(contents.replace(old_path, str(local_archive)))
PY

cat > "$toolchain_dir/bin/g++" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
toolchain_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$toolchain_dir/root/usr/bin/g++" \
  -idirafter "$toolchain_dir/root/usr/include/x86_64-linux-gnu" \
  -idirafter "$toolchain_dir/root/usr/include" "$@"
EOF
cat > "$toolchain_dir/bin/gcc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
toolchain_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$toolchain_dir/root/usr/bin/gcc" \
  -idirafter "$toolchain_dir/root/usr/include/x86_64-linux-gnu" \
  -idirafter "$toolchain_dir/root/usr/include" "$@"
EOF
chmod +x "$toolchain_dir/bin/g++" "$toolchain_dir/bin/gcc"

printf -v quoted_dir '%q' "$toolchain_dir"
printf 'export VERILOG_TOOLCHAIN_ROOT=%s\n' "$quoted_dir" > "$toolchain_dir/env.sh"
cat >> "$toolchain_dir/env.sh" <<'EOF'
export PATH="$VERILOG_TOOLCHAIN_ROOT/bin:$VERILOG_TOOLCHAIN_ROOT/root/usr/bin:$PATH"
export VERILATOR_ROOT="$VERILOG_TOOLCHAIN_ROOT/root/usr/share/verilator"
export LD_LIBRARY_PATH="$VERILOG_TOOLCHAIN_ROOT/root/usr/lib/x86_64-linux-gnu:$VERILOG_TOOLCHAIN_ROOT/root/usr/lib:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$VERILOG_TOOLCHAIN_ROOT/root/usr/lib/x86_64-linux-gnu:$VERILOG_TOOLCHAIN_ROOT/root/usr/lib/x86_64-linux-gnu/15:$VERILOG_TOOLCHAIN_ROOT/root/usr/lib/gcc/x86_64-linux-gnu/15:${LIBRARY_PATH:-}"
EOF

# 버전 문자열뿐 아니라 컴파일러 링크와 시뮬레이터 실행을 직접 확인한다.
(
  . "$toolchain_dir/env.sh"
  printf 'int main() { return 0; }\n' > "$toolchain_dir/compiler-smoke.cpp"
  g++ "$toolchain_dir/compiler-smoke.cpp" -o "$toolchain_dir/compiler-smoke"
  "$toolchain_dir/compiler-smoke"
  verilator --version
  make --version | head -n 1
  g++ --version | head -n 1
)

printf '\n설치가 완료되었습니다. 새 셸을 열 때마다 다음 명령을 실행하세요:\n  source %q\n' "$toolchain_dir/env.sh"
printf '패키지 버전과 SHA-256 해시: %s\n' "$manifest"
