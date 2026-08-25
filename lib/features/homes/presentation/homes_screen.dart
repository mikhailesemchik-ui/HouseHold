import 'package:flutter/material.dart';

class HomesScreen extends StatelessWidget {
  const HomesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homes')),
      body: const Center(child: Text('Homes')),
    );
  }
}
