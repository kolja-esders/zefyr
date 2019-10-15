// Copyright (c) 2018, the Zefyr project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:notus/notus.dart';
import 'package:zefyr/util.dart';

import 'controller.dart';
import 'editable_box.dart';
import 'scope.dart';

RenderEditableBox _getEditableBox(HitTestResult result) {
  for (var entry in result.path) {
    if (entry.target is RenderEditableBox) {
      return entry.target as RenderEditableBox;
    }
  }
  return null;
}

/// Selection overlay controls selection handles and other gestures.
class ZefyrSelectionOverlay extends StatefulWidget {
  const ZefyrSelectionOverlay({
    Key key,
    @required this.controller,
    @required this.controls,
    @required this.overlay,
  }) : super(key: key);

  final ZefyrController controller;
  final TextSelectionControls controls;
  final OverlayState overlay;

  @override
  _ZefyrSelectionOverlayState createState() => new _ZefyrSelectionOverlayState();
}

class _ZefyrSelectionOverlayState extends State<ZefyrSelectionOverlay> implements TextSelectionDelegate {
  @override
  TextEditingValue get textEditingValue => widget.controller.plainTextEditingValue;

  set textEditingValue(TextEditingValue value) {
    final cursorPosition = value.selection.extentOffset;
    final oldText = widget.controller.document.toPlainText();
    final newText = value.text;
    final diff = fastDiff(oldText, newText, cursorPosition);
    widget.controller.replaceText(diff.start, diff.deleted.length, diff.inserted, selection: value.selection);
  }

  @override
  void bringIntoView(ui.TextPosition position) {
    // TODO: implement bringIntoView
  }

  bool get isToolbarVisible => _toolbar != null;

  bool get isToolbarHidden => _toolbar == null;

  @override
  void hideToolbar() {
    _toolbar?.remove();
    _toolbar = null;
    _toolbarController.stop();
  }

  void showToolbar() {
    final scope = ZefyrScope.of(context);
    assert(scope != null);
    final toolbarOpacity = _toolbarController.view;
    Offset paintOffset = _lastTapDownPosition != null
        ? _lastTapDownPosition
        : _longPressPosition != null
            ? _longPressPosition
            : Offset(_editor.selection.baseOffset.toDouble(), _editor.selection.extentOffset.toDouble());
    RenderEditableProxyBox renderObject = _editor?.renderContext?.boxForTextOffset(_editor?.selection?.baseOffset);
    _toolbar = new OverlayEntry(
      builder: (context) => new FadeTransition(
        opacity: toolbarOpacity,
        child: _SelectionToolbar(
          scope: scope,
          controls: widget.controls,
          delegate: this,
          renderObject: renderObject,
          paintOffset: paintOffset,
        ),
      ),
    );
    widget.overlay.insert(_toolbar);
    _toolbarController.forward(from: 0.0);
  }

  //
  // Overridden members of State
  //

  @override
  void initState() {
    super.initState();
    _toolbarController = new AnimationController(duration: _kFadeDuration, vsync: widget.overlay);
  }

  static const Duration _kFadeDuration = const Duration(milliseconds: 150);

  @override
  void didUpdateWidget(ZefyrSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overlay != widget.overlay) {
      hideToolbar();
      _toolbarController.dispose();
      _toolbarController = new AnimationController(duration: _kFadeDuration, vsync: widget.overlay);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final editor = ZefyrScope.of(context);
    if (_editor != editor) {
      _editor?.removeListener(_handleChange);
      _editor = editor;
      _editor.addListener(_handleChange);
      _selection = _editor.selection;
      _focusOwner = _editor.focusOwner;
    }
  }

  @override
  void dispose() {
    _editor.removeListener(_handleChange);
    hideToolbar();
    _toolbarController.dispose();
    _toolbarController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlay = new GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: _handleTapDown,
      onTap: _handleTap,
      onTapCancel: _handleTapCancel,
      onLongPress: _handleLongPress,
      child: new Stack(
        fit: StackFit.expand,
        children: <Widget>[
          new SelectionHandleDriver(
            position: _SelectionHandlePosition.base,
            controls: widget.controls,
          ),
          new SelectionHandleDriver(
            position: _SelectionHandlePosition.extent,
            controls: widget.controls,
          ),
        ],
      ),
    );
    return new Container(child: overlay);
  }

  //
  // Private members
  //

  /// Global position of last TapDown event.
  Offset _lastTapDownPosition;

  /// Global position of last TapDown which is potentially a long press.
  Offset _longPressPosition;

  OverlayEntry _toolbar;
  AnimationController _toolbarController;

  ZefyrScope _editor;
  TextSelection _selection;
  FocusOwner _focusOwner;

  void _handleChange() {
    if (_selection != _editor.selection || _focusOwner != _editor.focusOwner) {
      _updateToolbar();
    }
  }

  void _updateToolbar() {
    if (!mounted) {
      return;
    }
    final selection = _editor.selection;
    final focusOwner = _editor.focusOwner;
    setState(() {
      if (focusOwner != FocusOwner.editor) {
        hideToolbar();
      } else {
        if (_selection != selection) {
          if (selection.isCollapsed && isToolbarVisible) hideToolbar();
          _toolbar?.markNeedsBuild();
          if (!selection.isCollapsed && isToolbarHidden) showToolbar();
        } else {
          if (!selection.isCollapsed && isToolbarHidden) {
            showToolbar();
          } else if (isToolbarVisible) {
            _toolbar?.markNeedsBuild();
          }
        }
      }
      _selection = selection;
      _focusOwner = focusOwner;
    });
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() {
      _lastTapDownPosition = details.globalPosition;
    });
  }

  void _handleTapCancel() {
    setState(() {
      // longPress arrives after tapCancel, so remember the tap position.
      _longPressPosition = _lastTapDownPosition;
    });
  }

  void _handleTap() {
    assert(_lastTapDownPosition != null);
    final globalPoint = _lastTapDownPosition;
    _lastTapDownPosition = null;
    HitTestResult result = new HitTestResult();
    WidgetsBinding.instance.hitTest(result, globalPoint);

    RenderEditableProxyBox box = _getEditableBox(result);
    if (box == null) {
      box = _editor.renderContext.closestBoxForGlobalPoint(globalPoint);
    }
    if (box == null) return null;

    final localPoint = box.globalToLocal(globalPoint);
    final position = box.getPositionForOffset(localPoint);
    final selection = new TextSelection.collapsed(
      offset: position.offset,
      affinity: position.affinity,
    );
    widget.controller.updateSelection(selection, source: ChangeSource.local);
  }

  void _handleLongPress() async {
    final Offset globalPoint = _longPressPosition;
    HitTestResult result = new HitTestResult();
    WidgetsBinding.instance.hitTest(result, globalPoint);
    final box = _getEditableBox(result);
    if (box == null) {
      if (isToolbarVisible) {
        hideToolbar();
      } else {
        HapticFeedback.selectionClick();
        showToolbar();
      }
      return;
    }
    final localPoint = box.globalToLocal(globalPoint);
    final position = box.getPositionForOffset(localPoint);
    final word = box.getWordBoundary(position);
    final selection = new TextSelection(
      baseOffset: word.start,
      extentOffset: word.end,
    );

    if (word.start == word.end) {
      if (isToolbarVisible) {
        hideToolbar();
      } else {
        HapticFeedback.selectionClick();
        showToolbar();
      }
    }

    // Provide haptic feedback for a non-empty selection.
    if (word.start < word.end) HapticFeedback.selectionClick();

    widget.controller.updateSelection(selection, source: ChangeSource.local);
  }

  @override
  // TODO: implement copyEnabled
  bool get copyEnabled => true;

  @override
  bool get cutEnabled => true;

  @override
  bool get pasteEnabled => true;

  @override
  bool get selectAllEnabled => false;
}

enum _SelectionHandlePosition { base, extent }

class SelectionHandleDriver extends StatefulWidget {
  const SelectionHandleDriver({
    Key key,
    @required this.position,
    @required this.controls,
  }) : super(key: key);

  final _SelectionHandlePosition position;
  final TextSelectionControls controls;

  @override
  _SelectionHandleDriverState createState() => new _SelectionHandleDriverState();
}

class _SelectionHandleDriverState extends State<SelectionHandleDriver> {
  ZefyrScope _scope;

  /// Current document selection.
  TextSelection get selection => _selection;
  TextSelection _selection;

  /// Returns `true` if this handle is located at the baseOffset of selection.
  bool get isBaseHandle => widget.position == _SelectionHandlePosition.base;

  /// Character offset of this handle in the document.
  ///
  /// For base handle this equals to [TextSelection.baseOffset] and for
  /// extent handle - [TextSelection.extentOffset].
  int get documentOffset => isBaseHandle ? selection.baseOffset : selection.extentOffset;

  /// Position in pixels of this selection handle within its paragraph [block].
  Offset getPosition(RenderEditableBox block) {
    if (block == null) return null;

    final localSelection = block.getLocalSelection(selection);
    assert(localSelection != null);

    final boxes = block.getEndpointsForSelection(selection);
    assert(boxes.isNotEmpty, 'Got empty boxes for selection ${selection}');

    final box = isBaseHandle ? boxes.first : boxes.last;
    // Quickfix: Move left handle 22 pixels to the left in order to put it to the right position.
    final dx = isBaseHandle ? box.start - 22 : box.end;
    return new Offset(dx, box.bottom);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = ZefyrScope.of(context);
    if (_scope != scope) {
      _scope?.removeListener(_handleScopeChange);
      _scope = scope;
      _scope.addListener(_handleScopeChange);
    }
    _selection = _scope.selection;
  }

  @override
  void dispose() {
    _scope?.removeListener(_handleScopeChange);
    super.dispose();
  }

  //
  // Overridden members
  //

  @override
  Widget build(BuildContext context) {
    if (selection == null ||
        selection.isCollapsed ||
        widget.controls == null ||
        _scope.focusOwner != FocusOwner.editor) {
      return new Container();
    }
    final block = _scope.renderContext.boxForTextOffset(documentOffset);
    final position = getPosition(block);
    Widget handle;
    if (position == null) {
      handle = new Container();
    } else {
      final handleType = isBaseHandle ? TextSelectionHandleType.left : TextSelectionHandleType.right;
      handle = new Positioned(
        left: position.dx,
        top: position.dy,
        child: widget.controls.buildHandle(
          context,
          handleType,
          block.preferredLineHeight,
        ),
      );
      handle = new CompositedTransformFollower(
        link: block.layerLink,
        showWhenUnlinked: false,
        child: new Stack(
          overflow: Overflow.visible,
          children: <Widget>[handle],
        ),
      );
    }
    // Always return this gesture detector even if handle is an empty container
    // This way we prevent drag gesture from being canceled in case current
    // position is somewhere outside of any visible paragraph block.
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        CustomPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<CustomPanGestureRecognizer>(
          () => CustomPanGestureRecognizer(onPanDown: _handleDragStart, onPanUpdate: _handleDragUpdate),
          (CustomPanGestureRecognizer instance) {},
        ),
      },
      child: handle,
    );
  }

  //
  // Private members
  //

  Offset _dragPosition;

  void _handleScopeChange() {
    if (_selection != _scope.selection) {
      setState(() {
        _selection = _scope.selection;
      });
    }
  }

  bool _handleDragStart(Offset details) {
    _dragPosition = Offset(details.dx, details.dy-50);
    return true;
  }

  void _handleDragUpdate(Offset details) {
    _dragPosition = Offset(details.dx, details.dy-50);
    final globalPoint = _dragPosition;
    final paragraph = _scope.renderContext.boxForGlobalPoint(globalPoint);
    if (paragraph == null) {
      return;
    }

    final localPoint = paragraph.globalToLocal(globalPoint);
    final position = paragraph.getPositionForOffset(localPoint);
    final newSelection = selection.copyWith(
      baseOffset: isBaseHandle ? position.offset : selection.baseOffset,
      extentOffset: isBaseHandle ? selection.extentOffset : position.offset,
    );
    if (newSelection.baseOffset >= newSelection.extentOffset) {
      // Don't allow reversed or collapsed selection.
      return;
    }

    if (newSelection != _selection) {
      _scope.updateSelection(newSelection, source: ChangeSource.local);
    }
  }
}

class CustomPanGestureRecognizer extends OneSequenceGestureRecognizer {
  final Function onPanDown;
  final Function onPanUpdate;

  CustomPanGestureRecognizer({
    @required this.onPanDown,
    @required this.onPanUpdate,
  });

  @override
  void addPointer(PointerEvent event) {
    if (onPanDown(event.position)) {
      startTrackingPointer(event.pointer);
      resolve(GestureDisposition.accepted);
    } else {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onPanUpdate(event.position);
    }
    if (event is PointerUpEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  String get debugDescription => 'customPan';

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

class _SelectionToolbar extends StatefulWidget {
  const _SelectionToolbar(
      {Key key,
      @required this.scope,
      @required this.controls,
      @required this.delegate,
      this.renderObject,
      this.paintOffset})
      : super(key: key);

  final ZefyrScope scope;
  final TextSelectionControls controls;
  final TextSelectionDelegate delegate;
  final RenderEditableProxyBox renderObject;
  final Offset paintOffset;

  @override
  _SelectionToolbarState createState() => new _SelectionToolbarState();
}

class _SelectionToolbarState extends State<_SelectionToolbar> {
  ZefyrScope get editable => widget.scope;

  TextSelection get selection => widget.delegate.textEditingValue.selection;

  @override
  Widget build(BuildContext context) {
    return _buildToolbar(context);
  }

  Widget _buildToolbar(BuildContext context) {
    final base = selection.baseOffset;
    // TODO: Editable is not refreshed and may contain stale renderContext instance.
    final block = editable.renderContext.boxForTextOffset(base);
    if (block == null) {
      return Container();
    }
    final boxes = block.getEndpointsForSelection(selection);
    // Find the horizontal midpoint, just above the selected text.
    Offset midpoint = new Offset(
      (boxes.length == 1) ? (boxes[0].start + boxes[0].end) / 2.0 : (boxes[0].start + boxes[1].start) / 2.0,
      boxes[0].bottom - block.preferredLineHeight,
    );
    List<TextSelectionPoint> endpoints;
    if (boxes.length == 1) {
      midpoint = Offset((boxes[0].start + boxes[0].end) / 2.0, boxes[0].bottom - block.preferredLineHeight);
      final Offset start = Offset(boxes[0].start, block.preferredLineHeight);
      endpoints = <TextSelectionPoint>[TextSelectionPoint(start, null)];
    } else {
      midpoint = Offset((boxes[0].start + boxes[1].start) / 2.0, boxes[0].bottom - block.preferredLineHeight);
      final Offset start = Offset(boxes.first.start, boxes.first.bottom);
      final Offset end = Offset(boxes.last.end, boxes.last.bottom);
      endpoints = <TextSelectionPoint>[
        TextSelectionPoint(start, boxes.first.direction),
        TextSelectionPoint(end, boxes.last.direction),
      ];
    }

    final Rect editingRegion = new Rect.fromPoints(
      block.localToGlobal(Offset.zero),
      block.localToGlobal(block.size.bottomRight(Offset.zero)),
    );
    final toolbar = widget.controls.buildToolbar(
        context, editingRegion, widget.renderObject.preferredLineHeight, midpoint, endpoints, widget.delegate);
    return new CompositedTransformFollower(
      link: block.layerLink,
      showWhenUnlinked: false,
      offset: -editingRegion.topLeft,
      child: toolbar,
    );
  }
}
