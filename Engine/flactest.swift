import AVFoundation
let f = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
print(f.fileFormat, f.length)
