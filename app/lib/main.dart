import 'package:flutter/material.dart';

void main() {
  runApp(const SyndaiApp());
}

class SyndaiApp extends StatelessWidget {
  const SyndaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Syndai',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D6A4F)),
        useMaterial3: true,
      ),
      home: const _Placeholder(),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Syndai scaffold — lanes A/B/C in flight.',
          style: TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}
