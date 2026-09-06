#!/bin/sh

set -eu

ARCH=$(uname -m)

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm \
	clang                   \
	cmake                   \
	git                     \
	gtk3                    \
	libayatana-appindicator \
	lld                     \
	llvm                    \
	ninja                   \
	rustup                  \
	unzip                   \
	wget                    \
	which                   \
	xz

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
get-debloated-pkgs --add-common --prefer-nano ! llvm-libs

echo "Building LocalSend..."
echo "---------------------------------------------------------------"
case "$ARCH" in
	x86_64)  farch=x64;;
	aarch64) farch=arm64;;
	*) >&2 echo "Unsupported arch: $ARCH"; exit 1;;
esac

git clone https://github.com/localsend/localsend.git ./localsend && (
	cd ./localsend

	# Build the latest stable tag
	TAG=$(git tag --list 'v*' --sort=-v:refname | grep -vi 'rc\|alpha\|beta' | head -n 1)
	git checkout "$TAG"
	echo "$TAG" > ~/version

	# Flutter's template adds -Wall -Werror which fails the tray_manager
	# plugin on newer libayatana-appindicator (deprecated declarations)
	sed -i \
		'/target_compile_options(${TARGET} PRIVATE -Wall -Werror)/a\  target_compile_options(${TARGET} PRIVATE -Wno-error=deprecated-declarations)' \
		./app/linux/CMakeLists.txt

	cargo fetch --locked --target host-tuple
	cargo build --frozen --release --all-features

	# Copy isolate so flutter can find it
	mkdir -p ./app/build/linux/"$farch"/release/plugins/rust_lib_localsend_app
	cp ./target/release/librust_lib_localsend_app.so ./app/build/linux/"$farch"/release/plugins/rust_lib_localsend_app

	# Install the Flutter SDK pinned in .fvmrc
	FLUTTER_VERSION=$(sed -n 's/.*"flutter": *"\([^"]*\)".*/\1/p' .fvmrc)
	git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
	export PATH="/opt/flutter/bin:$PATH"

	cd ./app
	flutter config --no-analytics >/dev/null
	flutter pub get
	flutter build linux --no-pub --release
)

echo "Installing LocalSend to /usr..."
echo "---------------------------------------------------------------"
mkdir -p /usr/lib/localsend
cp -r ./localsend/app/build/linux/"$farch"/release/bundle/. /usr/lib/localsend
cp ./localsend/target/release/localsend-cli ./localsend/target/release/server /usr/lib/localsend
cp -v ./localsend/app/assets/img/logo-512.png ./AppDir

# Set rpath so the bundled libraries are found relative to the binary
for i in /usr/lib/localsend/localsend_app /usr/lib/localsend/localsend-cli /usr/lib/localsend/server; do
	patchelf --set-rpath '$ORIGIN/lib' "$i"
done
for i in /usr/lib/localsend/lib/*; do
	[ -f "$i" ] || continue
	readelf -h "$i" >/dev/null 2>&1 || continue
	patchelf --set-rpath '$ORIGIN' "$i"
done

ln -sf /usr/lib/localsend/localsend_app /usr/bin/localsend

