import 'package:flutter/material.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load the native libopus shared library.
  // MUST be called before any SimpleOpusDecoder is created.
  // Without this every decode() throws 'Opus not initialized' → packets
  // are silently dropped → buffer never fills → app stuck on buffering.
  initOpus(await opus_flutter.load());

  runApp(const Mix2GoApp());
}

class Mix2GoApp extends StatelessWidget {
  const Mix2GoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: HomePage()); 
  }
}
