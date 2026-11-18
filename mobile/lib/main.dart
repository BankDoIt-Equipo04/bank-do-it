import 'package:flutter/material.dart';

void main() => runApp(const BankDoItApp());

class BankDoItApp extends StatelessWidget {
  const BankDoItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BANKDOIT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007985)),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const Scaffold(
        body: Center(
          child: Text(
            'BANKDOIT',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}
