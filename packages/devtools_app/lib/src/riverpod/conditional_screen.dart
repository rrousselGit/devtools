// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:graphview/graphview.dart';
import 'package:graphview/graphview.dart' as g;

import '../eval_on_dart_library.dart';
import '../globals.dart';
import '../screen.dart';

/// This is an example implementation of a conditional screen that supports
/// offline mode and uses a provided controller [ExampleController].
///
/// This class exists solely as an example and should not be used in the
/// DevTools app.
class RiverpodInspector extends Screen {
  const RiverpodInspector()
      : super.conditional(
          id: id,
          requiresLibrary: 'package:riverpod/',
          title: 'Riverpod inspector',
          icon: Icons.waves,
        );

  static const id = 'riverpod';

  @override
  Widget build(BuildContext context) {
    return const _RiverpodInspectorBody();
  }
}

final _eval = Provider<EvalOnDartLibrary>((ref) {
  return EvalOnDartLibrary(
    {'package:flutter_riverpod/src/framework.dart'},
    serviceManager.service,
  );
});

final _initialNodes = FutureProvider<List<Node>>((ref) async {
  final eval = ref.watch(_eval);

  final providerElementsRef = await eval
      .getInstance(
        eval.eval('debugGenerateProviderGraph()', isAlive: null),
        null,
      )
      .then((e) => e.elements.cast<InstanceRef>());

  final providerElements = await Future.wait<Instance>(
    [for (final ref in providerElementsRef) eval.getInstance(ref, null)],
  );

  print('Found ${providerElements.length} ProviderElement');

  // TODO handle add/remove of ProviderContainers
  // TODO handle add/remove of ProviderElement

  return await Future.wait<Node>([
    for (final ref in providerElements) parseNode(ref, eval),
  ]);
});

final _elementIds = FutureProvider<List<String>>((ref) async {
  final nodes = await ref.watch(_initialNodes.future);

  return [
    for (final node in nodes) node.id,
  ];
});

final _nodes =
    StreamProvider.autoDispose.family<Node, String>((ref, id) async* {
  final initialNodes = await ref.watch(_initialNodes.future);
  final initialNode = initialNodes.firstWhere((s) => s.id == id);

  yield initialNode;

  // TODO handle updates
});

final $graph = Provider.autoDispose<AsyncValue<Graph>>((ref) {
  final ids = ref.watch(_elementIds);
  if (ids.data == null) return ids.whenData(null);

  final nodes = <String, Node>{};
  final gNodes = <String, g.Node>{};

  for (final id in ids.data.value) {
    final node = ref.watch(_nodes(id));
    if (node.data == null) {
      return node.whenData(null);
    }
    nodes[id] = node.data.value;
    gNodes[id] = g.Node(Text(
        '${node.data.value.name} ${node.data.value.type}#${node.data.value.hash}'));
  }

  final graph = Graph();

  for (final node in nodes.values) {
    if (node.children.isEmpty)
      graph.addNode(gNodes[node.id]);
    else {
      for (final childId in node.children) {
        graph.addEdge(
          gNodes[childId],
          gNodes[node.id],
        );
      }
    }
  }

  return AsyncValue.data(graph);
});

class _RiverpodInspectorBody extends ConsumerWidget {
  const _RiverpodInspectorBody({Key key}) : super(key: key);

  @override
  Widget build(BuildContext context, ScopedReader watch) {
    // final ids = watch(_elementIds);

    return watch($graph).when(
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) => Text('Error $err\n$stack'),
      data: (graph) {
        return InteractiveViewer(
          constrained: false,
          // scaleEnabled: false,
          boundaryMargin: EdgeInsets.all(100),
          minScale: 0.01,
          maxScale: 5.6,
          child: GraphView(
            graph: graph,
            algorithm: SugiyamaAlgorithm(
              SugiyamaConfiguration(),
            ),
          ),
        );
      },
    );

    // return Center(
    //   child: ids.when(
    //     loading: () => const CircularProgressIndicator(),
    //     error: (err, stack) => Text('Error $err\n$stack'),
    //     data: (ids) {
    //       return ListView.builder(
    //         itemCount: ids.length,
    //         itemBuilder: (context, index) {
    //           final id = ids[index];

    //           return NodeTile(id);
    //         },
    //       );
    //     },
    //   ),
    // );
  }
}

final _parsedValue = FutureProvider.family
    .autoDispose<Instance, InstanceRef>((ref, instanceRef) async {
  final eval = ref.watch(_eval);

  return eval.getInstance(instanceRef, null);
});

class Value {
  Value({
    @required this.type,
    @required this.hash,
    @required this.properties,
  });

  final String type;
  final String hash;
  final Map<String, Object> properties;
}

class NodeTile extends ConsumerWidget {
  const NodeTile(this.id, {Key key}) : super(key: key);

  final String id;

  @override
  Widget build(BuildContext context, ScopedReader watch) {
    final node = watch(_nodes(id));

    return node.when(
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) => Text('Error at id $id: $err\n$stack'),
      data: (node) {
        return InstanceRefView(
          node.value,
          name: node.name ?? node.type ?? '<fallback>',
        );
      },
    );
  }
}

class InstanceRefView extends ConsumerWidget {
  const InstanceRefView(
    this.value, {
    Key key,
    @required this.name,
  }) : super(key: key);

  final InstanceRef value;
  final String name;

  @override
  Widget build(BuildContext context, ScopedReader watch) {
    return watch(_parsedValue(value)).when(
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) => Text('Parse Error: $err\n$stack'),
      data: (value) {
        if (value.valueAsString != null) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name),
              const SizedBox(width: 10),
              Text(value.valueAsString),
            ],
          );
        }

        return ExpansionTile(
          title: Text(name),
          children: [
            ...watch(_parsedValue(value)).when(
              loading: () => const [CircularProgressIndicator()],
              error: (err, stack) => [Text('Parse Error: $err\n$stack')],
              data: (value) {
                return [
                  if (value.fields.isNotEmpty)
                    for (final field in value.fields)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: InstanceRefView(
                          field.value as InstanceRef,
                          name: field.decl.name,
                        ),
                      )
                  else if (value.elements != null)
                    for (final item in value.elements.cast<InstanceRef>())
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: InstanceRefView(
                          item,
                          name: item.classRef.name,
                        ),
                      )
                ];
              },
            )
          ],
        );
      },
    );
  }
}

extension on VmService {
  Stream<Event> watchEvent(String eventName) {
    return onExtensionEvent.where((event) {
      return event.extensionKind == eventName;
    });
  }
}

extension on List<BoundField> {
  BoundField firstWithName(String name) {
    return firstWhere((e) => e.decl.name == name);
  }
}

Future<Node> parseNode(Instance ref, EvalOnDartLibrary eval) async {
  final hashRef = ref.fields.firstWithName('hash').value as InstanceRef;
  final nameRef = ref.fields.firstWithName('name').value as InstanceRef;
  final typeRef = ref.fields.firstWithName('type').value as InstanceRef;
  final firstUsageStackTraceRef =
      ref.fields.firstWithName('firstUsageStackTrace').value as InstanceRef;
  final idRef = ref.fields.firstWithName('id').value as InstanceRef;
  final childrenRef = await eval
      .getInstance(
        ref.fields.firstWithName('children').value as InstanceRef,
        null,
      )
      .then((e) => e.elements.cast<InstanceRef>());

  // final children = childrenRef.map((ref) async {
  // return nodeForRef(await eval.getInstance(ref, null));
  // });

  return Node._(
    id: idRef.valueAsString,
    children: [for (final ref in childrenRef) ref.valueAsString],
    hash: int.tryParse(hashRef.valueAsString),
    name: nameRef?.valueAsString,
    firstUsageStackTrace: firstUsageStackTraceRef?.valueAsString,
    type: typeRef.name,
    value: ref.fields.firstWithName('value').value as InstanceRef,
  );
}

// Copied from flutter_riverpod/src/devtool.dart

/// A simplified representation of a [ProviderElement].
///
/// This is used by the devtool to show te content of all providers.
class Node {
  Node._({
    @required this.id,
    @required this.value,
    @required this.name,
    @required this.type,
    @required this.hash,
    @required this.children,
    @required this.firstUsageStackTrace,
  });

  /// The value of a provider.
  ///
  /// This value is not serializable.
  final InstanceRef value;

  /// The runtimeType of a Provider, used as a fallback name in case [name] is missing
  final String type;

  /// The hashCode of a Provider, used as a fallback name in case [name] is missing
  final int hash;

  /// A unique identifier specific to the [ProviderElement]
  final String id;

  /// The name of a provider. Can be null.
  final String name;

  /// A string representation of the [StackTrace] of when the provider was created.
  final String firstUsageStackTrace;

  /// All the [ProviderElement] that depends on this provider.
  final List<String> children;
}
