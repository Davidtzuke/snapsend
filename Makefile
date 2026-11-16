.PHONY: build install clean

build:
	@scripts/build.sh

install:
	@scripts/build.sh --install

clean:
	rm -rf build
