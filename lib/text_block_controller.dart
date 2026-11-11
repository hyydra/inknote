import 'package:flutter/material.dart';

import 'note_data.dart';
import 'rich_text_controller.dart';

class TextBlockController {
  final VoidCallback onChanged;
  final VoidCallback onFocusChanged;
  final List<RichTextEditingController> controllers = [];
  final List<FocusNode> focusNodes = [];
  final List<TextBlockFormat> formats = [];
  int _activeIndex = 0;

  TextBlockController({
    required this.onChanged,
    required this.onFocusChanged,
  });

  int get activeIndex => _activeIndex;

  set activeIndex(int index) {
    _activeIndex =
        controllers.isEmpty ? 0 : index.clamp(0, controllers.length - 1);
  }

  void replace(
    Iterable<String> blocks, {
    Iterable<TextBlockFormat>? formats,
  }) {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final focusNode in focusNodes) {
      focusNode.dispose();
    }
    final savedBlocks = blocks.toList();
    final savedFormats = formats?.toList() ?? const <TextBlockFormat>[];
    this.formats
      ..clear()
      ..addAll(List.generate(
        savedBlocks.length,
        (index) => index < savedFormats.length
            ? _copyFormat(savedFormats[index])
            : TextBlockFormat(y: 48 + index * 184),
      ));
    controllers
      ..clear()
      ..addAll(List.generate(
        savedBlocks.length,
        (index) => _createTextController(
          savedBlocks[index],
          this.formats[index].styles,
        ),
      ));
    focusNodes
      ..clear()
      ..addAll(List.generate(savedBlocks.length, (_) => _createFocusNode()));
    activeIndex = _activeIndex;
  }

  int add() {
    final format = TextBlockFormat(
      x: 48 + (controllers.length % 3) * 24,
      y: 48 + controllers.length * 184,
    );
    formats.add(format);
    controllers.add(_createTextController('', format.styles));
    focusNodes.add(_createFocusNode());
    activeIndex = controllers.length - 1;
    return activeIndex;
  }

  void removeAt(int index) {
    controllers.removeAt(index).dispose();
    focusNodes.removeAt(index).dispose();
    formats.removeAt(index);
    activeIndex = _activeIndex;
  }

  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final focusNode in focusNodes) {
      focusNode.dispose();
    }
  }

  RichTextEditingController _createTextController(
    String text,
    List<TextStyleRange> styles,
  ) {
    final controller = RichTextEditingController(text: text, styles: styles);
    controller.addListener(onChanged);
    return controller;
  }

  FocusNode _createFocusNode() {
    final focusNode = FocusNode();
    focusNode.addListener(onFocusChanged);
    return focusNode;
  }

  TextBlockFormat _copyFormat(TextBlockFormat format) => TextBlockFormat(
        bold: format.bold,
        color: format.color,
        fontSize: format.fontSize,
        x: format.x,
        y: format.y,
        width: format.width,
        height: format.height,
        styles: format.styles
            .map((style) => TextStyleRange(
                  start: style.start,
                  end: style.end,
                  bold: style.bold,
                  color: style.color,
                  fontSize: style.fontSize,
                ))
            .toList(),
      );
}
