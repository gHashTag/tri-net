// TRI-NET Phone App — Video over Mesh
// Minimal: camera capture → UDP to mesh node → receive → display
// E1: loopback (send to self through mesh node)

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() => runApp(TriNetApp());

class TriNetApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TRI-NET Video',
      home: VideoMeshScreen(),
    );
  }
}

class VideoMeshScreen extends StatefulWidget {
  @override
  _VideoMeshScreenState createState() => _VideoMeshScreenState();
}

class _VideoMeshScreenState extends State<VideoMeshScreen> {
  String _status = 'Idle';
  String _meshNode = '192.168.1.11'; // P203 Mini node 1
  int _meshPort = 5000;
  RawDatagramSocket? _socket;
  int _framesSent = 0;
  int _framesReceived = 0;

  void _connectToMesh() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 9090);
      _socket!.broadcastEnabled = true;
      
      setState(() => _status = 'Connected to mesh node $_meshNode:$_meshPort');
      
      // Listen for incoming frames
      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            setState(() {
              _framesReceived++;
              _status = 'RX: $_framesReceived frames';
            });
          }
        }
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  void _sendTestFrame() {
    if (_socket == null) return;
    // Send a test frame (in real app: H.264 encoded camera frame)
    final data = Uint8List.fromList([
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, // frame header
      ...List.filled(64, 0xAA), // dummy frame data
    ]);
    _socket!.send(data, InternetAddress(_meshNode), _meshPort);
    setState(() {
      _framesSent++;
    });
  }

  @override
  void dispose() {
    _socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('TRI-NET Video Mesh'),
        backgroundColor: Colors.indigo,
      ),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(_status, style: TextStyle(fontSize: 16)),
            SizedBox(height: 20),
            Text('Mesh Node: $_meshNode:$_meshPort'),
            SizedBox(height: 20),
            TextField(
              decoration: InputDecoration(labelText: 'Mesh Node IP'),
              onChanged: (v) => _meshNode = v,
            ),
            SizedBox(height: 20),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _connectToMesh,
                  child: Text('Connect'),
                ),
                SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _sendTestFrame,
                  child: Text('Send Test Frame'),
                ),
              ],
            ),
            SizedBox(height: 20),
            Text('TX: $_framesSent frames', style: TextStyle(fontSize: 16)),
            Text('RX: $_framesReceived frames', style: TextStyle(fontSize: 16)),
            SizedBox(height: 30),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Architecture:', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Phone → UDP → P203 Mini → radio mesh → P203 Mini → UDP → Phone'),
                    SizedBox(height: 8),
                    Text('E1: Loopback test (this app)'),
                    Text('E2: Two-phone via mesh (next)'),
                    Text('E3: Multi-hop video (future)'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
