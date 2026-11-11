.PHONY: all build debug cert install run test selftest screenshots clean

all: build

build:
	@scripts/build-app.sh release

debug:
	@scripts/build-app.sh debug

cert:
	@scripts/make-cert.sh

install: build
	@pkill -x Flit || true
	@rm -rf /Applications/Flit.app
	@cp -R build/Flit.app /Applications/Flit.app
	@open /Applications/Flit.app
	@echo "Installed and launched /Applications/Flit.app"

run: build
	@pkill -x Flit || true
	@open build/Flit.app

# Command Line Tools ship swift-testing outside the default search path.
CLT=/Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS=-Xswiftc -F -Xswiftc $(CLT)/Frameworks -Xlinker -F -Xlinker $(CLT)/Frameworks \
  -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib
test:
	@swift test $(TEST_FLAGS) 2>&1 | grep -E 'error:|✘|✔|Test run'

# Drives the real hotkeys against a throwaway window (about 3 min; hands off the keyboard).
# One section only: make selftest ONLY=dimming
selftest:
	@scripts/selftest.sh $(ONLY)

# Regenerates docs/screenshots from sample data and a demo app (about 20 s; hands off the keyboard).
screenshots:
	@scripts/screenshots.sh

clean:
	@rm -rf build .build
