import 'dart:io';

/// bump_version.dart
///  - 默认从当前工作目录向上查找最近的 pubspec.yaml 并递增 patch 位
///  - 可通过 --pubspec 指定 pubspec.yaml 路径
///  - 支持 --dry-run 仅打印将要写入的版本而不修改文件
/// 退出码：0 成功；1 失败（供 git hooks 使用）
void main(List<String> args) {
  try {
    final argMap = _parseArgs(args);
    final dryRun = argMap.containsKey('dry-run');
    final explicitPath = argMap['pubspec'] as String?;

    final pubspecFile =
        explicitPath != null && explicitPath.isNotEmpty ? File(explicitPath) : _findNearestPubspec(Directory.current);

    if (pubspecFile == null || !pubspecFile.existsSync()) {
      stderr.writeln('未找到 pubspec.yaml，请使用 --pubspec 指定或在项目目录下运行。');
      exit(1);
    }

    final content = pubspecFile.readAsStringSync();

    // 匹配 version: x.y.z 或 version: x.y.z+build
    final reg = RegExp(r'^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?\s*$', multiLine: true);
    final match = reg.firstMatch(content);
    if (match == null) {
      stderr.writeln('未找到有效的 version 字段，格式应为: version: x.y.z 或 version: x.y.z+build');
      exit(1);
    }

    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    final build = match.group(4); // 可能为 null

    final nextPatch = patch + 1;
    final newVersion = '$major.$minor.$nextPatch${build != null ? '+$build' : ''}';

    final newContent = content.replaceFirst(match.group(0)!, 'version: $newVersion');

    if (dryRun) {
      stdout.writeln('[DRY-RUN] ${pubspecFile.path} 将更新版本: $major.$minor.$patch -> $newVersion');
      exit(0);
    }

    pubspecFile.writeAsStringSync(newContent);
    stdout.writeln('version 自动递增: ${pubspecFile.path}  $major.$minor.$patch -> $newVersion');
    exit(0);
  } catch (e, st) {
    stderr.writeln('bump_version 失败: $e');
    stderr.writeln(st);
    exit(1);
  }
}

Map<String, Object?> _parseArgs(List<String> args) {
  final map = <String, Object?>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--dry-run') {
      map['dry-run'] = true;
    } else if (a == '--pubspec') {
      if (i + 1 < args.length) {
        map['pubspec'] = args[++i];
      } else {
        stderr.writeln('参数 --pubspec 需要提供文件路径');
        exit(1);
      }
    }
  }
  return map;
}

/// 从起始目录向上查找最近的 pubspec.yaml
File? _findNearestPubspec(Directory startDir) {
  Directory dir = startDir.absolute;
  while (true) {
    final candidate = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    if (candidate.existsSync()) return candidate;

    final parent = dir.parent;
    if (parent.path == dir.path) {
      // 已经到达根目录
      return null;
    }
    dir = parent;
  }
}
