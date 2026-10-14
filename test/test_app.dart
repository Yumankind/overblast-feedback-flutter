import 'package:flutter/material.dart';
import 'package:overblast_feedback/overblast_feedback.dart';

/// A small screen with the things the picker and the capture must handle.
class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your cart')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CartRow(title: 'Blue mug', price: '12.00'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(key: const ValueKey('cart.remove'), onPressed: () {}, child: const Text('Remove')),
          ),
          const OverblastPrivate(
            child: SizedBox(
              key: ValueKey('iban'),
              width: 200,
              height: 40,
              child: ColoredBox(color: Colors.white, child: Text('PT50 0002 0123 1234 5678 9015 4')),
            ),
          ),
          const SizedBox(width: 200, child: TextField(key: ValueKey('password'), obscureText: true)),
          Semantics(
            identifier: 'cart.total',
            child: const Text('Total 12.00', key: ValueKey('total-text')),
          ),
        ],
      ),
    );
  }
}

class CartRow extends StatelessWidget {
  const CartRow({super.key, required this.title, required this.price});

  final String title;
  final String price;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Text(title), const SizedBox(width: 16), Text(price)]),
  );
}
