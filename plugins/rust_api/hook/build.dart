import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {
        'LIBCLANG_PATH': directory.path,
        ..._bindgenClangArgs(input, llvmRoot),
      };
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

// The NDK's libclang is an older major version than the bundled Clang and,
// once bindgen passes a cross-compilation `--target`, it stops finding its own
// builtin headers (stdbool.h and friends live in lib/clang/<ver>/include).
// Point it at them explicitly so rquickjs-sys can bind QuickJS on Android.
Map<String, String> _bindgenClangArgs(BuildInput input, Directory llvmRoot) {
  final triple = switch (input.config.code.targetArchitecture) {
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.arm => 'armv7-linux-androideabi',
    Architecture.x64 => 'x86_64-linux-android',
    Architecture.ia32 => 'i686-linux-android',
    _ => null,
  };
  if (triple == null) {
    return const {};
  }
  final sysrootTriple = triple == 'armv7-linux-androideabi'
      ? 'arm-linux-androideabi'
      : triple;
  final sep = Platform.pathSeparator;
  final sysroot = '${llvmRoot.path}${sep}sysroot';
  final builtinInclude = _builtinIncludeDir(llvmRoot);
  if (builtinInclude == null) {
    return const {};
  }
  final args =
      '--sysroot=$sysroot -I$sysroot/usr/include/$sysrootTriple '
      '-isystem ${builtinInclude.path}';
  return {
    'BINDGEN_EXTRA_CLANG_ARGS_${triple.replaceAll('-', '_')}': args
        // NOTE: force the use of forward-slash path separators
        .replaceAll(r'\', '/'),
  };
}

Directory? _builtinIncludeDir(Directory llvmRoot) {
  final clangRoot = Directory(
    '${llvmRoot.path}${Platform.pathSeparator}lib'
    '${Platform.pathSeparator}clang',
  );
  if (!clangRoot.existsSync()) {
    return null;
  }
  final candidates = clangRoot
      .listSync()
      .whereType<Directory>()
      .where((d) {
    final include = Directory(
      '${d.path}${Platform.pathSeparator}include',
    );
    return include.existsSync();
  }).toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  if (candidates.isEmpty) {
    return null;
  }
  return Directory(
    '${candidates.first.path}${Platform.pathSeparator}include',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
