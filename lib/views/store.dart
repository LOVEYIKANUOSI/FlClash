import 'package:flutter/material.dart';

class StoreView extends StatelessWidget {
  const StoreView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('商店'),
        centerTitle: true,
      ),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('商店功能开发中', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
