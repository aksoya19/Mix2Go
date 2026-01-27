import 'package:flutter/material.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const Mix2GoApp());
}

class Mix2GoApp extends StatelessWidget {
  const Mix2GoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: HomePage()); 
  }
}
