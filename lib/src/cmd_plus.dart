// ignore_for_file: avoid-non-ascii-symbols
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cmd_plus/src/model/model.dart';
import 'package:cmd_plus/src/utility/utility.dart';
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart' hide ExitCode;
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as path;

/// {@template cmd_plus}
/// [CmdPlus] is a class that provides a simple methods to run processes on the command
/// line. It is a wrapper around the [Process] class, making it easier to
/// log errors and process results with package:mason_logger.
/// {@endtemplate}
class CmdPlus {
  /// {@macro cmd_plus}
  CmdPlus({
    Logger? logger,
    this.manager,
  }) : logger = logger ??
            Logger(
              progressOptions: const ProgressOptions(
                animation: ProgressAnimation(
                  frames: ['🌑', '🌒', '🌓', '🌔', '🌕', '🌖', '🌗', '🌘'],
                ),
              ),
            );

  /// The logger to use to log errors and process results.
  final Logger logger;

  /// The manager for the process.
  ProcessManager? manager;

  /// Frees up resources associated with this class.
  Future<void> close() async {
    await sharedStdIn.terminate();
  }

  /// {@template copy_directory}
  /// {@macro cmd_plus}
  ///
  ///
  /// [copyDirectory] copies the files from the directory [from]
  /// to the directory [to].
  ///
  /// [filters] can be specified to ignore certain files and folders,
  /// and to replace certain strings in the file or folder names and in content.
  ///
  /// IMPORTANT: This method will wipe the contents of the [to] directory
  /// completely before copying the files.
  /// {@endtemplate}
  Future<void> copyDirectory({
    required Directory from,
    required Directory to,
    List<DirectoryCopyFilter> filters = const [],
    bool enableLogging = true,
  }) async {
    final copyProgress = enableLogging
        ? logger.progress('Copying files from ${from.path} to ${to.path}')
        : null;
    await to.recreate();

    final ignorePaths =
        filters.whereType<IgnorePathsDirectoryCopyFilter>().toList();

    final replaceInFolderNames =
        filters.whereType<ReplaceInFolderNamesDirectoryCopyFilter>().toList();

    final replaceInFileNames =
        filters.whereType<ReplaceInFileNamesDirectoryCopyFilter>().toList();

    final replaceInFileContent =
        filters.whereType<ReplaceInFileContentDirectoryCopyFilter>().toList();

    await Future.wait(
      from.listSync(recursive: true).whereType<File>().map(
        (originalFile) async {
          final relativePath = originalFile.relativePath(from);

          final shouldIgnore = ignorePaths.any(
            (ignore) => ignore.paths.any(
              (r) => r.hasMatch(relativePath),
            ),
          );

          if (shouldIgnore) return;

          final folderNameFilters = replaceInFolderNames.where(
            (replace) => !replace.ignore.any(
              (r) => r.hasMatch(relativePath),
            ),
          );

          final filteredFolderName = folderNameFilters.fold<String>(
            path.dirname(relativePath),
            (previousValue, filter) => previousValue.replaceAll(
              filter.from,
              filter.replace,
            ),
          );

          final fileNameFilters = replaceInFileNames.where(
            (replace) => !replace.ignore.any(
              (r) => r.hasMatch(relativePath),
            ),
          );

          final filteredFileName = fileNameFilters.fold<String>(
            path.basename(relativePath),
            (previousValue, filter) => previousValue.replaceAll(
              filter.from,
              filter.replace,
            ),
          );

          final filteredPath = path.join(
            to.absolute.path,
            filteredFolderName,
            filteredFileName,
          );

          final contentFilters = replaceInFileContent.where(
            (replace) => !replace.ignore.any(
              (r) => r.hasMatch(relativePath),
            ),
          );

          await copyFile(
            from: originalFile,
            to: File(filteredPath),
            filters: contentFilters
                .map(
                  (f) => FileCopyFilter.replaceInFileContent(
                    from: f.from,
                    replace: f.replace,
                  ),
                )
                .toList(),
            enableLogging: false,
          );
        },
      ),
    );

    copyProgress?.complete();
  }

  /// {@template copy_file}
  /// {@macro cmd_plus}
  ///
  ///
  /// [copyFile] copies the file [from] to the file [to], while applying
  /// the given [FileCopyFilter]s.
  ///
  /// IMPORTANT: this method will overwrite the contents of [to] if it already
  /// already exists.
  Future<void> copyFile({
    required File from,
    required File to,
    List<FileCopyFilter> filters = const [],
    bool enableLogging = true,
  }) async {
    final progress = enableLogging
        ? logger.progress('Copying file from ${from.path} to ${to.path}')
        : null;
    if (to.existsSync()) {
      await to.delete();
    }
    await to.create(recursive: true);
    if (filters.isEmpty) {
      await from.copy(to.absolute.path);
    } else {
      final content = await from.readAsString();
      final filteredContent = filters.fold<String>(
        content,
        (previousValue, filter) => previousValue.replaceAll(
          filter.from,
          filter.replace,
        ),
      );
      await to.writeAsString(filteredContent);
    }

    progress?.complete();
  }

  /// {@template start}
  /// {@macro cmd_plus}
  ///
  ///
  /// [start] starts a process running the [cmd] with the specified
  /// [args].
  ///
  /// Use [throwOnError] to specify whether to throw an exception
  /// if theprocess fails or not. Defaults to `true`.
  ///
  /// Use [runInShell] to specify whether to run the process through a
  /// system shell. If [runInShell] is true, the process will be spawned
  /// through a system shell. On Linux and OS X, /bin/sh is used, while
  /// %WINDIR%\system32\cmd.exe is used on Windows. Defaults to `true`.
  ///
  /// Use [includeParentEnvironment] to specify whether to include the parent
  /// process's environment. If [includeParentEnvironment] is true, the
  /// process's environment will include the parent process's environment,
  /// with [environment] taking precedence. Defaults to `true`.
  ///
  /// Use [workingDirectory] to set the working directory for the process.
  /// NOTE: the change of directory occurs before executing the process
  /// on some platforms, which may have impact when using relative paths for
  /// the executable and the arguments.
  ///
  /// Use [environment] to set the environment variables for the process.
  /// If not set the environment of the parent process is inherited.
  /// Currently, only US-ASCII environment variables are supported and errors
  /// are likely to occur if an environment variable with code-points outside
  /// the US-ASCII range is passed in.
  ///
  /// Use [mode] to specify how the process should be run. Defaults to
  /// [CmdPlusMode.normal()].
  /// {@endtemplate}
  Future<CmdPlusResult> start(
    String cmd,
    List<String> args, {
    bool throwOnError = true,
    bool runInShell = true,
    bool includeParentEnvironment = true,
    String? workingDirectory,
    Map<String, String>? environment,
    CmdPlusMode mode = const CmdPlusMode.normal(),
  }) async {
    manager ??= ProcessManager();
    final process = await _overrideAnsiOutput(
      true,
      () => mode.when(
        normal: () => manager!.spawn(
          cmd,
          args,
          workingDirectory: workingDirectory,
          runInShell: runInShell,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
        ),
        background: () => manager!.spawnBackground(
          cmd,
          args,
          workingDirectory: workingDirectory,
          runInShell: runInShell,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
        ),
        detached: () => manager!.spawnDetached(
          cmd,
          args,
          workingDirectory: workingDirectory,
          runInShell: runInShell,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
        ),
      ),
    );

    var output = '';
    var error = '';

    final outSubscription = process.stdout.transform(utf8.decoder).listen(
          (o) => output += o,
        );

    final errSubscription = process.stderr.transform(utf8.decoder).listen(
          (e) => error += e,
        );

    final exitCode = await process.exitCode;

    if (throwOnError && exitCode != 0) {
      await outSubscription.cancel();
      await errSubscription.cancel();
      throw ProcessException(
        cmd,
        args,
        'Process exited with exit code $exitCode',
        exitCode,
      );
    }

    await outSubscription.cancel();
    await errSubscription.cancel();

    return CmdPlusResult(
      exitCode: exitCode,
      output: output,
      error: error,
    );
  }

  /// {@template run}
  /// {@macro cmd_plus}
  ///
  ///
  /// [run] starts a process and runs it non-interactively to completion.
  /// The process run [cmd] with the specified [args].
  ///
  /// Use [throwOnError] to specify whether to throw an exception
  /// if theprocess fails or not. Defaults to `true`.
  ///
  /// Use [runInShell] to specify whether to run the process through a
  /// system shell. If [runInShell] is true, the process will be spawned
  /// through a system shell. On Linux and OS X, /bin/sh is used, while
  /// %WINDIR%\system32\cmd.exe is used on Windows. Defaults to `true`.
  ///
  /// Use [includeParentEnvironment] to specify whether to include the parent
  /// process's environment. If [includeParentEnvironment] is true, the
  /// process's environment will include the parent process's environment,
  /// with [environment] taking precedence. Defaults to `true`.
  ///
  /// Use [workingDirectory] to set the working directory for the process.
  /// NOTE: the change of directory occurs before executing the process
  /// on some platforms, which may have impact when using relative paths for
  /// the executable and the arguments.
  ///
  /// Use [environment] to set the environment variables for the process.
  /// If not set the environment of the parent process is inherited.
  /// Currently, only US-ASCII environment variables are supported and errors
  /// are likely to occur if an environment variable with code-points outside
  /// the US-ASCII range is passed in.
  ///
  /// Use [mode] to specify how the process should be run. Defaults to
  /// [CmdPlusMode.normal()].
  /// {@endtemplate}
  Future<CmdPlusResult> run(
    String cmd,
    List<String> args, {
    bool throwOnError = true,
    bool runInShell = true,
    bool includeParentEnvironment = true,
    String? workingDirectory,
    Map<String, String>? environment,
    CmdPlusMode mode = const CmdPlusMode.normal(),
  }) async {
    final result = await _overrideAnsiOutput(
      true,
      () => Process.run(
        cmd,
        args,
        workingDirectory: workingDirectory,
        runInShell: runInShell,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
      ),
    );

    final error = result.stderr.toString();
    final output = result.stdout.toString();
    final showOutput = mode.maybeMap<bool>(
      detached: (_) => false,
      orElse: () => true,
    );

    if (showOutput) {
      if (output.isNotEmpty) logger.write(output);
      if (error.isNotEmpty) logger.err(error);
    }

    if (throwOnError && result.exitCode != 0) {
      throw ProcessException(
        cmd,
        args,
        'Process exited with exit code $exitCode',
        exitCode,
      );
    }

    return CmdPlusResult(
      exitCode: exitCode,
      output: output,
      error: error,
    );
  }

  T _overrideAnsiOutput<T>(bool enableAnsiOutput, T Function() body) =>
      runZoned(
        body,
        zoneValues: <Object, Object>{
          ansi.AnsiCode: enableAnsiOutput,
          AnsiCode: enableAnsiOutput,
        },
      );
}
