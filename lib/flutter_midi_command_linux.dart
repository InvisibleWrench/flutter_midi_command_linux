import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'alsa_generated_bindings.dart' as a;

final alsa = a.ALSA(DynamicLibrary.open("libasound.so.2"));

class LinuxMidiDevice extends MidiDevice {
  Pointer<Pointer<a.snd_rawmidi_>> out_port;

  LinuxMidiDevice(String id, String name, String type, bool connected)
      : super(id, name, type, connected) {}
}

class FlutterMidiCommandLinux extends MidiCommandPlatform {
  StreamController<Uint8List> _rxStreamController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> _rxStream = StreamController<Uint8List>.broadcast().stream;
  StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  Stream<String> _setupStream;

  Pointer<Int8> port_name;
  Pointer<Pointer<a.snd_rawmidi_>> in_port;
  // Pointer<Pointer<a.snd_rawmidi_>> out_port;

  Map<String, LinuxMidiDevice> _connectedDevices =
      Map<String, LinuxMidiDevice>();

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    in_port = allocate();
    // out_port = allocate();
    // port_name = Utf8.toUtf8("hw:1,0,0");

    // int result =
    //     rawMIDIOpen(in_port, out_port, port_name, SND_RAWMIDI_NONBLOCK);
    // print('Result: $result ${statusMessage(result)}');
  }

  String stringFromNative(Pointer<Int8> pointer) {
    return Utf8.fromUtf8(pointer.cast<Utf8>());
  }

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void register() {
    print("register FlutterMidiCommandLinux");
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    // _printMidiPorts();
    return Future.value(_printCardList());
  }

  List<MidiDevice> _printCardList() {
    print("_printCardList");
    int status;
    var card = allocate<Int32>(count: 1);
    card.elementAt(0).value = -1;
    Pointer<Pointer<Int8>> longname = allocate();
    Pointer<Pointer<Int8>> shortname = allocate();

    List<MidiDevice> cards = List<MidiDevice>();

    if ((status = alsa.snd_card_next(card)) < 0) {
      print(
          'error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
      return null;
    }
    // print('status $status');
    if (card.value < 0) {
      print('error: no sound cards found');
      return null;
    }

    while (card.value >= 0) {
      // print("card ${card.value}");
      if ((status = alsa.snd_card_get_name(card.value, shortname)) < 0) {
        print(
            'error: cannot determine card shortname $card ${stringFromNative(alsa.snd_strerror(status))}');
        break;
      }
      // print('status $status');
      // if ((status = alsa.snd_card_get_longname(card.value, longname)) < 0) {
      //   print(
      //       'error: cannot determine card longname $card ${stringFromNative(alsa.snd_strerror(status))}');
      //   break;
      // }
      // print('status $status');
      print(
          "card shortname ${stringFromNative(shortname.value)} card ${card.value}");

      cards.add(LinuxMidiDevice(
          card.value.toString(),
          stringFromNative(shortname.value),
          "native",
          _connectedDevices.containsKey(card.value.toString())));

      if ((status = alsa.snd_card_next(card)) < 0) {
        print(
            'error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
        return cards;
      }
    }

    return cards;
  }

  void _printMidiPorts() {
    print("_printMidiPorts");
    int status;
    var card = allocate<Int32>(count: 1);
    card.elementAt(0).value = -1;

    if ((status = alsa.snd_card_next(card)) < 0) {
      print(
          'error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
      return;
    }
    if (card.value < 0) {
      print('error: no sound cards found');
      return;
    }

    print('device:');
    while (card.value >= 0) {
      // print("card value ${card.value}");
      _listMidiDevicesOnCard(card.value);

      if ((status = alsa.snd_card_next(card)) < 0) {
        print(
            'error: cannot determine next card number $card ${stringFromNative(alsa.snd_strerror(status))}');
        break;
      }
    }
    print('end');
  }

  void _listMidiDevicesOnCard(int card) {
    Pointer<Pointer<a.snd_ctl_>> ctl = allocate<Pointer<a.snd_ctl_>>(count: 1);
    Pointer<Int8> name = Utf8.toUtf8("hw:$card").cast();
    Pointer<Int32> device = allocate<Int32>(count: 1);
    device.elementAt(0).value = -1;
    int status = -1;

    print(
        'device on card [$card] ${stringFromNative(name)} ctl: $ctl device $device status $status');
    status = alsa.snd_ctl_open(ctl, name, 0);
    // print("status after ctl_open $status");
    if (status < 0) {
      print(
          'error: cannot open control for card number $card ${stringFromNative(alsa.snd_strerror(status))}');
      return;
    }
    // print("do device.value ${device.value}");
    do {
      // print("ctl $ctl device $device");
      status = alsa.snd_ctl_rawmidi_next_device(ctl.value, device);
      print("status $status device.value ${device.value}");
      if (status < 0) {
        print(
            'error: cannot determine device number ${device.value} ${stringFromNative(alsa.snd_strerror(status))}');
        break;
      }
      if (device.value >= 0) {
        _listSubdeviceInfo(ctl.value, card, device.value);
      }
    } while (device.value > 0);
  }

  void _listSubdeviceInfo(Pointer<a.snd_ctl_> ctl, int card, int device) {
    Pointer<a.snd_rawmidi_info_> info = allocate<a.snd_rawmidi_info_>(count: 1);
    Pointer<Int8> name = allocate();

    print("_listSubdeviceInfo");

    int status = alsa.snd_ctl_rawmidi_info(ctl, info);
    print("status $status info ${info}");
    if (status < 0) {
      print(
          'error: cannot get device info ${stringFromNative(alsa.snd_strerror(status))}');
      return;
    }
    print('info ${info}');
    name = alsa.snd_rawmidi_info_get_name(info);
    print('name ${stringFromNative(name)}');
    free(info);
    free(name);
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {}

  /// Stops scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {}

  /// Connects to the device.
  @override
  void connectToDevice(MidiDevice device) {
    print('connect to $device');

    var linuxDevice = device as LinuxMidiDevice;
    linuxDevice.out_port = allocate();

    Pointer<Int8> name = Utf8.toUtf8("hw:${device.id},0,0").cast<Int8>();
    print("open ${stringFromNative(name)}");
    int status = 0;
    if ((status = alsa.snd_rawmidi_open(
            nullptr, linuxDevice.out_port, name, a.SND_RAWMIDI_NONBLOCK)) <
        0) {
      print(
          'error: cannot open card number ${device.id} ${stringFromNative(alsa.snd_strerror(status))}');
      return;
    }
    _connectedDevices[device.id] = device;
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (_connectedDevices.containsKey(device.id)) {
      var linuxDevice = device as LinuxMidiDevice;
      int status = 0;
      if ((status = alsa.snd_rawmidi_drain(linuxDevice.out_port.value)) < 0) {
        print(
            'error: cannot drain port ${device} ${stringFromNative(alsa.snd_strerror(status))}');
      }
      if ((status = alsa.snd_rawmidi_close(linuxDevice.out_port.value)) < 0) {
        print(
            'error: cannot close port ${device} ${stringFromNative(alsa.snd_strerror(status))}');
      }
      if (remove) _connectedDevices.remove(device.id);
    }
  }

  @override
  void teardown() {
    print("teardown");

    _connectedDevices.values.forEach((device) {
      disconnectDevice(device, remove: false);
    });
    _connectedDevices.clear();
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data) {
    print("send $data through buffer");

    // if (deviceId != null && connectedDevices.containsKey(deviceId)) {
    //   connectedDevices[deviceId]?.let {
    //     it.send(data)
    //   }
    // } else {

    final buffer = allocate<Uint8>(count: data.length);
    for (var i = 0; i < data.length; i++) {
      buffer[i] = data[i];
    }
    final voidBuffer = buffer.cast<Void>();

    _connectedDevices.values.forEach((device) {
      print("send to $device");
      int status;
      if ((status = alsa.snd_rawmidi_write(
              device.out_port.value, voidBuffer, data.length)) <
          0) {
        print('failed to write ${stringFromNative(alsa.snd_strerror(status))}');
      }
    });

    free(buffer);
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<Uint8List> get onMidiDataReceived {
    print("get on midi data");
    // _rxStream ??= _rxChannel.receiveBroadcastStream().map<Uint8List>((d) {
    //   return Uint8List.fromList(List<int>.from(d));
    // });
    _rxStream ??= _rxStreamController.stream;
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String> get onMidiSetupChanged {
    _setupStream ??= _setupStreamController.stream;
    return _setupStream;
  }
}
