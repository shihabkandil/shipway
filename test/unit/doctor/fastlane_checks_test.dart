import 'package:shipway/src/doctor/checks/fastlane_checks.dart';
import 'package:test/test.dart';

void main() {
  group('recognising a fastlane wrapper script', () {
    test('the real Homebrew shim', () {
      // Verbatim shape of /opt/homebrew/bin/fastlane: a bash script that
      // replaces GEM_HOME and GEM_PATH before exec'ing the real binary, which
      // is what makes `bundle exec fastlane` silently use the wrong gems.
      const shim = '''
#!/bin/bash
PATH="/brew/opt/ruby/bin:\$PATH" FASTLANE_INSTALLED_VIA_HOMEBREW="true" \\
GEM_HOME="\${FASTLANE_GEM_HOME:-\${HOME}/.local/share/fastlane/3.4.0}" \\
GEM_PATH="\${FASTLANE_GEM_HOME:-\${HOME}/.local/share/fastlane/3.4.0}" \\
exec "/brew/Cellar/fastlane/2.226.0_1/libexec/bin/fastlane" "\$@"
''';
      expect(FastlaneShimCheck.isShim(shim), isTrue);
    });

    test('a wrapper that overrides GEM_HOME without the Homebrew marker', () {
      const shim = '#!/bin/sh\nGEM_HOME=/somewhere exec /real/fastlane "\$@"\n';
      expect(FastlaneShimCheck.isShim(shim), isTrue);
    });

    test('an ordinary bundler binstub is not a shim', () {
      // The fix this check recommends must not itself trip the check.
      const binstub = '''
#!/usr/bin/env ruby
# frozen_string_literal: true
require "rubygems"
require "bundler/setup"
load Gem.bin_path("fastlane", "fastlane")
''';
      expect(FastlaneShimCheck.isShim(binstub), isFalse);
    });

    test('a plain rubygems wrapper is not a shim', () {
      const wrapper = '#!/usr/bin/env ruby\nload "fastlane"\n';
      expect(FastlaneShimCheck.isShim(wrapper), isFalse);
    });

    test('a binary is not a shim', () {
      expect(FastlaneShimCheck.isShim('\x7fELF...'), isFalse);
      expect(FastlaneShimCheck.isShim(''), isFalse);
    });
  });

  group('recognising Homebrew by where it lives', () {
    // A Homebrew formula's wrapper can change shape between releases; where
    // Homebrew puts things does not.
    test('Apple silicon, Intel, Linux and a custom prefix', () {
      for (final path in const <String>[
        '/opt/homebrew/bin/fastlane',
        '/usr/local/Cellar/fastlane/2.226.0/bin/fastlane',
        '/home/linuxbrew/.linuxbrew/bin/fastlane',
        '/Users/x/brew/Cellar/fastlane/2.226.0_1/libexec/bin/fastlane',
      ]) {
        expect(FastlaneShimCheck.isHomebrewPath(path), isTrue, reason: path);
      }
    });

    test('a Ruby version manager is not Homebrew', () {
      for (final path in const <String>[
        '/Users/x/.rvm/gems/ruby-3.1.1/bin/fastlane',
        '/Users/x/.rbenv/shims/fastlane',
        // Unresolved: the check follows symlinks before asking.
        '/usr/local/bin/fastlane',
      ]) {
        expect(FastlaneShimCheck.isHomebrewPath(path), isFalse, reason: path);
      }
    });
  });
}
