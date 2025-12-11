import 'dart:io';
import 'package:ffmpeg_helper/ffmpeg_helper.dart';

class FFMpegCommand {
  const FFMpegCommand({
    this.inputs = const [],
    this.args = const [],
    this.filterGraph,
    this.outputFilepath,
    this.returnProgress = true,
  });

  /// FFMPEG command inputs, such as assets and virtual devices.
  final List<FFMpegInput> inputs;

  /// All non-input arguments for the FFMPEG command, such as "map".
  final List<CliArguments> args;

  /// The graph of filters that produce the final video.
  final FilterGraph? filterGraph;

  /// The file path for the rendered video.
  final String? outputFilepath;

  final bool returnProgress;

  /// Converts this command to a series of CLI arguments, which can be
  /// passed to a `Process` for execution.
  List<String> toCli() {
    List<String> commands = [];
    List<String> inputsList = [];
    if (returnProgress && (Platform.isWindows || Platform.isAndroid)) {
      // ffmpeg 7 之后需要使用 'pipe:' 而不是 '-'
      inputsList.addAll(['-progress', 'pipe:']);
    }
    for (var input in inputs) {
      inputsList.addAll(input.args);
    }
    List<String> argsList = [];
    for (var arg in args) {
      argsList.addAll(arg.toArgs());
    }
    List<String> filtersList = [];
    if ((filterGraph != null) && (filterGraph!.chains.isNotEmpty)) {
      filtersList.addAll(['-filter_complex', filterGraph!.toCli()]);
    }
    commands.addAll(inputsList);
    commands.addAll(argsList);
    commands.addAll(filtersList);
    if (null != outputFilepath) {
      commands.add(outputFilepath!);
    }
    return commands;
  }
}
