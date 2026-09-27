#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
toolchain_dir=$project_root/build/toolchain
viewer_dir=$project_root/build/viewer
apt_dir=$viewer_dir/apt
install_root=$viewer_dir/root

if [[ ! -f $toolchain_dir/apt/sources.list || ! -f $toolchain_dir/env.sh ]]; then
  printf '먼저 bash scripts/setup-toolchain.sh를 실행하세요.\n' >&2
  exit 1
fi
for command_name in apt-get dpkg-deb sha256sum glib-compile-schemas; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '필수 명령이 없습니다: %s\n' "$command_name" >&2
    exit 1
  fi
done

mkdir -p -- "$apt_dir/lists/partial" "$apt_dir/archives/partial" "$viewer_dir/bin"
apt_options=(
  -o "Dir::Etc::sourcelist=$toolchain_dir/apt/sources.list"
  -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=$apt_dir/lists"
  -o "Dir::Cache::archives=$apt_dir/archives"
  -o "APT::Sandbox::User=$(id -un)"
  -o Debug::NoLocking=1
  -o APT::Get::AllowUnauthenticated=false
)

printf '서명된 Ubuntu 패키지 목록을 갱신합니다...\n'
apt-get "${apt_options[@]}" update
printf 'GTKWave와 필요한 라이브러리를 내려받습니다...\n'
rm -f -- "$apt_dir"/archives/*.deb
apt-get "${apt_options[@]}" install --download-only -y --no-install-recommends gtkwave

shopt -s nullglob
packages=("$apt_dir"/archives/*.deb)
if (( ${#packages[@]} == 0 )); then
  printf 'GTKWave 패키지를 내려받지 못했습니다.\n' >&2
  exit 1
fi

rm -rf -- "$install_root"
mkdir -p -- "$install_root"
manifest=$viewer_dir/package-manifest.tsv
printf 'package\tversion\tarchitecture\tsha256\n' > "$manifest"
for package_file in "${packages[@]}"; do
  package_name=$(dpkg-deb -f "$package_file" Package)
  package_version=$(dpkg-deb -f "$package_file" Version)
  package_arch=$(dpkg-deb -f "$package_file" Architecture)
  package_hash=$(sha256sum "$package_file")
  printf '%s\t%s\t%s\t%s\n' "$package_name" "$package_version" "$package_arch" "${package_hash%% *}" >> "$manifest"
  dpkg-deb -x "$package_file" "$install_root"
done
glib-compile-schemas "$install_root/usr/share/glib-2.0/schemas"

cat > "$viewer_dir/bin/gtkwave" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
viewer_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
viewer_root=$viewer_dir/root
export LD_LIBRARY_PATH="$viewer_root/usr/lib/x86_64-linux-gnu:$viewer_root/usr/lib:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$viewer_root/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GSETTINGS_SCHEMA_DIR="$viewer_root/usr/share/glib-2.0/schemas"
if [[ -d $viewer_root/usr/share/tcltk/tcl8.6 ]]; then
  export TCL_LIBRARY="$viewer_root/usr/share/tcltk/tcl8.6"
fi
if [[ -d $viewer_root/usr/share/tcltk/tk8.6 ]]; then
  export TK_LIBRARY="$viewer_root/usr/share/tcltk/tk8.6"
fi
exec "$viewer_root/usr/bin/gtkwave" "$@"
EOF
chmod +x "$viewer_dir/bin/gtkwave"

"$viewer_dir/bin/gtkwave" --version
printf '설치 완료: %s\n' "$viewer_dir/bin/gtkwave"
printf 'TX 파형 열기: %s/reports/evidence/v0.2/tx.vcd\n' "$project_root"
