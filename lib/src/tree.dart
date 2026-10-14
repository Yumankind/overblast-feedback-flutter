import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Visits [root]'s descendants depth first. [visit] returns whether to go into that element's
/// children.
void walkElements(Element root, bool Function(Element element) visit) {
  void go(Element e) {
    e.visitChildElements((child) {
      if (visit(child)) go(child);
    });
  }

  go(root);
}

/// [box]'s rectangle in [ancestor]'s coordinates, or null when it has no size yet or is not under
/// [ancestor].
Rect? rectIn(RenderBox box, RenderObject ancestor) {
  if (!box.attached || !box.hasSize) return null;
  try {
    final transform = box.getTransformTo(ancestor);
    return MatrixUtils.transformRect(transform, Offset.zero & box.size);
  } catch (_) {
    return null;
  }
}

/// Whether [object] was part of what [root] last painted.
///
/// A render object can be attached and laid out while not painted at all: the routes under an
/// opaque route in the navigator's overlay, an `Offstage`, an `IndexedStack`'s other children, an
/// `Opacity` of zero. Nothing on the render object says so, but the layer tree does: a repaint
/// boundary that its parent did not paint has a layer that is not attached under the parent's. So
/// this climbs to the nearest repaint boundary and follows its layer up to [root]'s, and also asks
/// every render ancestor [RenderObject.paintsChild] on the way.
bool isPainted(RenderObject object, RenderObject root) {
  if (!object.attached) return false;
  RenderObject? node = object;
  RenderObject? boundary;
  while (node != null && !identical(node, root)) {
    final parent = node.parent;
    if (parent == null) return false; // not under root at all
    if (!parent.paintsChild(node)) return false;
    if (boundary == null && node.isRepaintBoundary) boundary = node;
    node = parent;
  }
  if (node == null) return false;
  if (boundary == null) return true; // painted straight into root's own layer
  // `layer` is protected because only a render object's own paint may change it; reading it to see
  // whether a boundary is composited is what the debugging tools do too.
  // ignore: invalid_use_of_protected_member
  final rootLayer = root.layer;
  // ignore: invalid_use_of_protected_member
  Layer? layer = boundary.layer;
  if (rootLayer == null || layer == null) return false;
  while (layer != null) {
    if (identical(layer, rootLayer)) return true;
    layer = layer.parent;
  }
  return false;
}
