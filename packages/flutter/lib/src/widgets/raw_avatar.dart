// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'basic.dart';
import 'debug.dart';
import 'framework.dart';
import 'implicit_animations.dart';
import 'text.dart';

// Examples can assume:
// late String userAvatarUrl;

/// A shape that represents a user.
///
/// Typically used with a user's profile image, or, in the absence of
/// such an image, the user's initials.
///
/// If [foregroundImage] fails then [backgroundImage] is used. If
/// [backgroundImage] fails too, [backgroundColor] is used.
///
/// The [onBackgroundImageError] callback is ignored if [backgroundImage] is null.
///
/// The [onForegroundImageError] callback is ignored if [foregroundImage] is null.
///
/// {@tool snippet}
///
/// If the avatar is to have an image, the image should be specified in the
/// [backgroundImage] property:
///
/// ```dart
/// RawAvatar(
///   shape: const CircleBorder(),
///   backgroundImage: NetworkImage(userAvatarUrl),
/// )
/// ```
/// {@end-tool}
///
/// The image will be cropped to the specified [shape].
///
/// {@tool snippet}
///
/// If the avatar is to just have the user's initials, they are typically
/// provided using a [Text] widget as the [child] and a [backgroundColor]:
///
/// ```dart
/// RawAvatar(
///   backgroundColor: Color(0xFF42221A),
///   shape: const CircleBorder(),
///   child: const Text('AH'),
/// )
/// ```
/// {@end-tool}
class RawAvatar extends StatelessWidget {
  /// Creates a shape that represents a user.
  const RawAvatar({
    super.key,
    this.child,
    this.backgroundColor,
    this.backgroundImage,
    this.foregroundImage,
    this.onBackgroundImageError,
    this.onForegroundImageError,
    this.constraints,
    this.shape,
    this.boxShape,
    this.duration,
  }) : assert(backgroundImage != null || onBackgroundImageError == null),
       assert(foregroundImage != null || onForegroundImageError == null),
       assert(shape == null || boxShape == null);

  /// {@template flutter.widgets.RawAvatar.child}
  /// The widget below this widget in the tree.
  ///
  /// Typically a [Text] widget used to display the user's initials.
  ///
  /// If the avatar is intended to display an image, prefer using
  /// [backgroundImage] or [foregroundImage] instead.
  /// {@endtemplate}
  final Widget? child;

  /// {@template flutter.widgets.RawAvatar.backgroundColor}
  /// The color used to fill the avatar's shape.
  ///
  /// When this value changes, the avatar animates smoothly to the new color.
  /// {@endtemplate}
  final Color? backgroundColor;

  /// {@template flutter.widgets.RawAvatar.backgroundImage}
  /// The background image displayed inside the avatar.
  ///
  /// This image is typically used as a fallback when [foregroundImage]
  /// fails to load.
  ///
  /// If the avatar is intended to display initials instead, use [child].
  ///
  /// When this value changes, the avatar animates smoothly to the new image.
  /// {@endtemplate}
  final ImageProvider? backgroundImage;

  /// {@template flutter.widgets.RawAvatar.foregroundImage}
  /// The foreground image displayed inside the avatar.
  ///
  /// This image is typically used as the user's profile image.
  ///
  /// If loading this image fails, [backgroundImage] will be used instead.
  /// {@endtemplate}
  final ImageProvider? foregroundImage;

  /// {@template flutter.widgets.RawAvatar.onBackgroundImageError}
  /// Called when an error occurs while loading [backgroundImage].
  ///
  /// This callback is only used if [backgroundImage] is provided.
  /// {@endtemplate}
  final ImageErrorListener? onBackgroundImageError;

  /// {@template flutter.widgets.RawAvatar.onForegroundImageError}
  /// Called when an error occurs while loading [foregroundImage].
  ///
  /// This callback is only used if [foregroundImage] is provided.
  /// {@endtemplate}
  final ImageErrorListener? onForegroundImageError;

  /// {@template flutter.widgets.RawAvatar.shape}
  /// The shape used to define the avatar's outline.
  ///
  /// If provided, the avatar is painted using a [ShapeDecoration] with the
  /// given [ShapeBorder]. This takes precedence over [boxShape].
  ///
  /// Use this for custom shapes, such as [StarBorder] or a
  /// [RoundedRectangleBorder].
  /// {@endtemplate}
  final ShapeBorder? shape;

  /// {@template flutter.widgets.RawAvatar.boxShape}
  /// The shape used to paint the avatar.
  ///
  /// Defaults to [BoxShape.circle].
  /// {@endtemplate}
  final BoxShape? boxShape;

  /// The duration of the animation for changes in properties.
  ///
  /// If null, defaults to `const Duration(milliseconds: 200)`.
  final Duration? duration;

  /// {@template flutter.widgets.RawAvatar.constraints}
  /// The size constraints for the avatar in logical pixels.
  ///
  /// If [constraints] is specified, it determines the minimum and maximum dimensions
  /// of the avatar.
  ///
  /// If [constraints] is null, the avatar defaults to a fixed size of 40 logical pixels.
  /// {@endtemplate}
  final BoxConstraints? constraints;

  // Default size if nothing is specified.
  static const double _defaultSize = 40.0;

  // Default min if only max is specified.
  static const double _defaultMinSize = 0.0;

  // Default max if only min is specified.
  static const double _defaultMaxSize = double.infinity;

  BoxConstraints get _effectiveConstraints {
    if (constraints == null) {
      return const BoxConstraints.tightFor(width: _defaultSize, height: _defaultSize);
    }

    final bool hasMin = constraints!.minWidth != 0.0 || constraints!.minHeight != 0.0;
    final bool hasMax =
        constraints!.maxWidth != double.infinity || constraints!.maxHeight != double.infinity;

    if (!hasMin && !hasMax) {
      return const BoxConstraints.tightFor(width: _defaultSize, height: _defaultSize);
    }

    final double min = hasMin ? constraints!.minWidth : _defaultMinSize;
    final double max = hasMax ? constraints!.maxWidth : _defaultMaxSize;

    return BoxConstraints(minWidth: min, minHeight: min, maxWidth: max, maxHeight: max);
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMediaQuery(context));

    final Decoration decoration = _effectiveDecoration(
      shape: shape,
      boxShape: boxShape,
      color: backgroundColor,
      image: backgroundImage,
      onError: onBackgroundImageError,
    );

    final Decoration? foregroundDecoration = foregroundImage != null
        ? _effectiveDecoration(
            shape: shape,
            boxShape: boxShape,
            image: foregroundImage,
            onError: onForegroundImageError,
          )
        : null;

    Widget avatar = AnimatedContainer(
      duration: duration ?? const Duration(milliseconds: 200),
      constraints: _effectiveConstraints,
      decoration: decoration,
      foregroundDecoration: foregroundDecoration,
      child: child == null ? null : Center(child: child),
    );

    if (shape != null) {
      avatar = ClipPath(
        clipper: ShapeBorderClipper(shape: shape!),
        child: avatar,
      );
    }

    return avatar;
  }

  Decoration _effectiveDecoration({
    ShapeBorder? shape,
    BoxShape? boxShape,
    Color? color,
    ImageProvider? image,
    ImageErrorListener? onError,
  }) {
    final DecorationImage? decorationImage = image != null
        ? DecorationImage(image: image, fit: BoxFit.cover, onError: onError)
        : null;

    if (shape != null) {
      return ShapeDecoration(shape: shape, color: color, image: decorationImage);
    }

    return BoxDecoration(shape: boxShape ?? BoxShape.circle, color: color, image: decorationImage);
  }
}
