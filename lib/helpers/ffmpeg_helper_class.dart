import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:string_util_xx/string_util_xx.dart';
import 'package:util_xx/util_xx.dart';

import '../ffmpeg_helper.dart';

class FFMpegHelper {
  static final FFMpegHelper _singleton = FFMpegHelper._internal();
  factory FFMpegHelper() => _singleton;
  FFMpegHelper._internal();
  static FFMpegHelper get instance => _singleton;

  String? defHttpUserAgent;
  late String _ffmpegInstallationPath;

  String? get ffmpegDirPath => _ffmpegInstallationPath;

  static String? Function(List<int>)? toDartString;

  static String parseFFmpegOutToJson(String str) {
    final result = StringBuffer();
    final list = str.split(RegExp('\r|\n', multiLine: true));
    int groupHit = 0;
    for (int i = 0; i < list.length; ++i) {
      final line = list[i];
      if (line.isEmpty) {
        continue;
      }
      if (groupHit > 0) {
        result.write(line);
        if (line == "}") {
          --groupHit;
        }
      } else if (line == "{") {
        // 开始解析json
        result.write(line);
        ++groupHit;
      }
    }
    return result.toString();
  }

  Future<void> initialize(String? defUA, String windir) async {
    defHttpUserAgent = defUA;
    if (Platform.isWindows) {
      _ffmpegInstallationPath = windir;
    } else {
      _ffmpegInstallationPath = "";
    }
  }

  Future<bool> isFFMpegPresent() async {
    if (Platform.isWindows) {
      final file_ffmpeg = File("$_ffmpegInstallationPath/ffmpeg.exe");
      final file_ffprobe = File("$_ffmpegInstallationPath/ffprobe.exe");
      if (false ==
          ((await file_ffmpeg.exists() && await file_ffprobe.exists()))) {
        return false;
      }
      return true;
    } else if (Platform.isLinux) {
      try {
        Process process = await Process.start(
          'ffmpeg',
          ['--help'],
        );
        return await process.exitCode == ReturnCode.success;
      } catch (e) {
        return false;
      }
    } else {
      return true;
    }
  }

  /// 执行命令
  /// * Future<FFMpegHelperSession> 完成时并不代表命令执行完成
  /// * [onComplete] 才会在执行完成后调用，因此如果需要拿命令的直接结果，需要在 onComplete 中获取
  Future<FFMpegHelperSession> runAsync(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runAsyncOnWindows(
        command,
        statisticsCallback: statisticsCallback,
        onComplete: onComplete,
      );
    } else {
      return _runAsyncOnNonWindows(
        command,
        statisticsCallback: statisticsCallback,
        onComplete: onComplete,
      );
    }
  }

  Future<FFMpegHelperSession> _runAsyncOnWindows(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    Process process = await _startWindowsProcess(
      command,
      statisticsCallback: statisticsCallback,
    );
    process.exitCode.then((value) {
      if (value == ReturnCode.success) {
        onComplete?.call(File(command.outputFilepath ?? ""));
      } else {
        onComplete?.call(null);
      }
    });
    return FFMpegHelperSession(
      windowSession: process,
      cancelSession: () async {
        process.kill(ProcessSignal.sigkill);
      },
    );
  }

  Future<FFMpegHelperSession> _runAsyncOnNonWindows(
    FFMpegCommand command, {
    void Function(Statistics statistics)? statisticsCallback,
    void Function(File? outputFile)? onComplete,
  }) async {
    FFmpegSession sess = await FFmpegKit.executeAsync(
      command.toCli().join(' '),
      (FFmpegSession session) async {
        final code = await session.getReturnCode();
        if (code?.isValueSuccess() == true) {
          onComplete?.call(File(command.outputFilepath ?? ""));
        } else {
          onComplete?.call(null);
        }
      },
      null,
      (Statistics statistics) {
        statisticsCallback?.call(statistics);
      },
    );
    return FFMpegHelperSession(
      nonWindowSession: sess,
      cancelSession: () async {
        await sess.cancel();
      },
    );
  }

  /// 执行命令
  /// * 在执行完成后才返回 Future 的结果
  Future<File?> runSync(
    FFMpegCommand command, {
    Duration? timeout,
    void Function(String)? onStdOut,
    void Function(String)? onStdErr,
    Function(Statistics statistics)? statisticsCallback,
  }) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runSyncOnWindows(
        command,
        timeout: timeout,
        onStdOut: onStdOut,
        onStdErr: onStdErr,
        statisticsCallback: statisticsCallback,
      );
    } else {
      return _runSyncOnNonWindows(
        command,
        timeout: timeout,
        statisticsCallback: statisticsCallback,
      );
    }
  }

  Future<Process> _startWindowsProcess(
    FFMpegCommand command, {
    void Function(String)? onStdOut,
    void Function(String)? onStdErr,
    void Function(Statistics statistics)? statisticsCallback,
  }) async {
    String ffmpeg = 'ffmpeg';
    if (Platform.isWindows) {
      ffmpeg = path.join(_ffmpegInstallationPath, "ffmpeg.exe");
    }
    Process process = await Process.start(
      ffmpeg,
      command.toCli(),
    );
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((String event) {
      onStdOut?.call(event);
      List<String> data = event.split("\n");
      Map<String, dynamic> temp = {};
      for (String element in data) {
        List<String> kv = element.split("=");
        if (kv.length == 2) {
          temp[kv.first] = kv.last;
        }
      }
      if (temp.isNotEmpty) {
        try {
          statisticsCallback?.call(Statistics(
            process.pid,
            double.tryParse(temp['frame'])?.toInt() ?? 0,
            double.tryParse(temp['fps']) ?? 0.0,
            double.tryParse(temp['stream_0_0_q']) ?? 0.0,
            double.tryParse(temp['total_size'])?.toInt() ?? 0,
            double.tryParse(temp['out_time_us'])?.toInt() ?? 0,
            // 2189.6kbits/s => 2189.6
            double.tryParse(
                    temp['bitrate']?.replaceAll(RegExp('[a-z/]'), '')) ??
                0.0,
            // 2.15x => 2.15
            double.tryParse(temp['speed']?.replaceAll(RegExp('[a-z/]'), '')) ??
                0.0,
          ));
        } catch (e) {
          if (kDebugMode) {
            print(e);
          }
        }
      }
    });
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((event) {
      onStdErr?.call(event);
      if (kDebugMode) {
        print("stderr: $event");
      }
    });
    return process;
  }

  Future<File?> _runSyncOnWindows(
    FFMpegCommand command, {
    Duration? timeout,
    void Function(String)? onStdOut,
    void Function(String)? onStdErr,
    void Function(Statistics statistics)? statisticsCallback,
  }) async {
    Process? process;
    try {
      process = await _startWindowsProcess(
        command,
        onStdOut: onStdOut,
        onStdErr: onStdErr,
        statisticsCallback: statisticsCallback,
      );
      Future<int?> code = process.exitCode;
      if (null != timeout) {
        code = code.timeout(timeout);
      }
      final result = await code;
      process.kill(ProcessSignal.sigkill);
      if (result == ReturnCode.success) {
        return File(command.outputFilepath ?? "");
      }
    } catch (e) {
      process?.kill(ProcessSignal.sigkill);
      if (kDebugMode) {
        print(e);
      }
    }
    return null;
  }

  Future<File?> _runSyncOnNonWindows(
    FFMpegCommand command, {
    Duration? timeout,
    void Function(Statistics statistics)? statisticsCallback,
  }) async {
    FFmpegSession? currSession;
    try {
      Completer<File?> completer = Completer<File?>();
      FFmpegKit.executeAsync(
        command.toCli().join(' '),
        (FFmpegSession session) async {
          currSession = session;
          final code = await session.getReturnCode();
          if (code?.isValueSuccess() == true) {
            if (!completer.isCompleted) {
              completer.complete(File(command.outputFilepath ?? ""));
            }
          } else {
            if (kDebugMode) {
              final logs = await session.getAllLogs();
              for (final item in logs) {
                // ignore: avoid_print
                print(item.getMessage());
              }
            }
            if (!completer.isCompleted) {
              completer.complete(null);
            }
          }
        },
        null,
        statisticsCallback,
      ).then((session) => currSession = session, onError: (e) {
        if (kDebugMode) {
          print(e);
        }
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });
      if (null != timeout) {
        return completer.future.timeout(
          timeout,
          onTimeout: () {
            if (null != currSession) {
              FFmpegKit.cancel(currSession!.getSessionId());
            }
            return null;
          },
        );
      }
      return completer.future;
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return null;
    }
  }

  Future<MediaInformation?> runProbe(
    String filePath, {
    Map<String, String>? header,
    Duration? timeout,
  }) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runProbeOnWindows(
        filePath,
        header: header,
        timeout: timeout,
      );
    } else {
      return _runProbeOnNonWindows(
        filePath,
        header: header,
        // timeout: timeout,
      );
    }
  }

  String? findHeader(Map<String, dynamic> header, String key) {
    for (final item in header.entries) {
      if (StringUtilxx_c.isIgnoreCaseEqual(item.key, key)) {
        // 替换
        return item.value;
      }
    }
    return null;
  }

  String? removeHeader(Map<String, dynamic> header, String key) {
    MapEntry<String, dynamic>? result;
    for (final item in header.entries) {
      if (StringUtilxx_c.isIgnoreCaseEqual(item.key, key)) {
        // 替换
        result = item;
        break;
      }
    }
    if (null != result) {
      header.remove(result.key);
      return result.value;
    }
    return null;
  }

  bool hasHeader(Map<String, String> header, String key) {
    return null != findHeader(header, key);
  }

  // 添加header
  bool insertHeader(Map<String, String> header, String key, String value) {
    for (final item in header.entries) {
      if (StringUtilxx_c.isIgnoreCaseEqual(item.key, key)) {
        // 替换
        header[item.key] = value;
        return true;
      }
    }
    return false;
  }

  String? getHeaderStr(Map<String, String>? header) {
    if (true != header?.isNotEmpty) {
      return null;
    }
    final list = header!.entries;
    final restr = StringBuffer();
    for (final item in list) {
      if (restr.isNotEmpty) {
        restr.write("\r\n");
      }
      restr.write("${item.key}: ${item.value}");
    }
    return restr.toString();
  }

  Future<MediaInformation?> _runProbeOnNonWindows(
    String path, {
    Map<String, String>? header,
    Duration? timeout,
  }) async {
    Completer<MediaInformation?> completer = Completer<MediaInformation?>();
    try {
      String? userAgent = defHttpUserAgent;
      if (null != header) {
        // 安卓端 ffmpeg-kit/5.1.0 添加ua到header后指定给 -headers 请求会报错返回null
        userAgent = removeHeader(header, "User-Agent") ?? defHttpUserAgent;
        // ffmpeg-6后，指定 header 和 ua 不要额外添加两端的双引号
      }
      final headerStr = getHeaderStr(header);
      final commandArguments = [
        "-v",
        "error",
        "-hide_banner",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        "-show_chapters",
        if (null != headerStr) "-headers",
        if (null != headerStr) headerStr,
        if (null != userAgent) "-user_agent",
        if (null != userAgent) userAgent,
        "-i",
        path,
      ];
      await FFprobeKit.getMediaInformationFromCommandArgumentsAsync(
        commandArguments,
        (MediaInformationSession session) async {
          final MediaInformation? information = session.getMediaInformation();
          if (information != null) {
            if (!completer.isCompleted) {
              completer.complete(information);
            }
          } else {
            if (kDebugMode) {
              final logs = await session.getAllLogs();
              for (final log in logs) {
                print(log.getLevel());
                print(log.getMessage());
              }
              print(await session.getOutput());
            }
            if (!completer.isCompleted) {
              completer.complete(null);
            }
          }
        },
        null,
        timeout?.inSeconds,
      );
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    return completer.future;
  }

  Map<String, String>? addHeader_defUA(Map<String, String>? header) {
    if (null != defHttpUserAgent) {
      header ??= Httpxx_c.createHeader();
      if (false == hasHeader(header, "User-Agent")) {
        // 还不存在，添加 ua
        header["User-Agent"] = defHttpUserAgent!;
      }
    }
    return header;
  }

  Future<MediaInformation?> _runProbeOnWindows(
    String filePath, {
    Map<String, String>? header,
    Duration? timeout,
  }) async {
    // TODO: 用 Process.start 时读取webdav会失败，且记得要 listen stdout，否则 exitCode 不触发
    String ffprobe = 'ffprobe';
    if (Platform.isWindows) {
      ffprobe = path.join(_ffmpegInstallationPath, "ffprobe.exe");
    }
    final useHeader = addHeader_defUA(header);
    // 默认是 utf8 编码
    final headerStr = getHeaderStr(useHeader);
    try {
      var resultFuture = Process.run(
        ffprobe,
        [
          '-v',
          'quiet',
          '-print_format',
          'json',
          '-show_format',
          '-show_streams',
          '-show_chapters',
          if (null != headerStr) "-headers",
          if (null != headerStr) headerStr,
          "-i",
          filePath,
        ],
        stdoutEncoding: null,
        stderrEncoding: const Utf8Codec(allowMalformed: true),
        // stdoutEncoding: const Utf8Codec(allowMalformed: true),
        // stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      if (null != timeout) {
        resultFuture = resultFuture.timeout(timeout);
      }
      final result = await resultFuture;
      if (result.stdout == null ||
          result.stdout is! Uint8List ||
          (result.stdout as Uint8List).isEmpty) {
        return null;
      }
      String stdout = "";
      final fileNameExt =
          StringUtilxx_c.getFileNameEXT(filePath)?.toLowerCase();
      if (null == fileNameExt || "wav" == fileNameExt) {
        // 检查乱码
        stdout = toDartString?.call(result.stdout) ??
            (const Utf8Decoder(allowMalformed: true)).convert(result.stdout);
      } else {
        stdout =
            (const Utf8Decoder(allowMalformed: true)).convert(result.stdout);
      }
      if (result.exitCode == ReturnCode.success) {
        final json = jsonDecode(stdout);
        return MediaInformation(json);
      } else {
        // if (kDebugMode) {
        //   print(result.stderr);
        // }
      }
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
    return null;
  }

  Future<FFMpegHelperSession> getThumbnailFileAsync({
    required String videoPath,
    required Duration fromDuration,
    required String outputPath,
    String? ffmpegPath,
    FilterGraph? filterGraph,
    int qualityPercentage = 100,
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    int quality = 1;
    if ((qualityPercentage > 0) && (qualityPercentage < 100)) {
      quality = (((100 - qualityPercentage) * 31) / 100).ceil();
    }
    final FFMpegCommand cliCommand = FFMpegCommand(
      returnProgress: true,
      inputs: [FFMpegInput.asset(videoPath)],
      args: [
        const OverwriteArgument(),
        SeekArgument(fromDuration),
        const CustomArgument(["-frames:v", '1']),
        CustomArgument(["-q:v", '$quality']),
      ],
      outputFilepath: outputPath,
      filterGraph: filterGraph,
    );
    FFMpegHelperSession session = await runAsync(
      cliCommand,
      onComplete: onComplete,
      statisticsCallback: statisticsCallback,
    );
    return session;
  }

  Future<File?> getThumbnailFileSync({
    required String videoPath,
    required Duration fromDuration,
    required String outputPath,
    String? ffmpegPath,
    FilterGraph? filterGraph,
    int qualityPercentage = 100,
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    int quality = 1;
    if ((qualityPercentage > 0) && (qualityPercentage < 100)) {
      quality = (((100 - qualityPercentage) * 31) / 100).ceil();
    }
    final FFMpegCommand cliCommand = FFMpegCommand(
      returnProgress: true,
      inputs: [FFMpegInput.asset(videoPath)],
      args: [
        const OverwriteArgument(),
        SeekArgument(fromDuration),
        const CustomArgument(["-frames:v", '1']),
        CustomArgument(["-q:v", '$quality']),
      ],
      outputFilepath: outputPath,
      filterGraph: filterGraph,
    );
    File? session = await runSync(
      cliCommand,
      statisticsCallback: statisticsCallback,
    );
    return session;
  }
}
