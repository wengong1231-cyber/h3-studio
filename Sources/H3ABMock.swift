import Foundation
import Darwin

private var abMockStop: Int32 = 0
enum H3ABMock {
    static func worker(_ requestURL: URL) -> Int32 {
        signal(SIGTERM) { _ in abMockStop = 1 };signal(SIGINT) { _ in abMockStop = 1 }
        var encoder: Process?
        defer { if let encoder,encoder.isRunning { encoder.terminate();encoder.waitUntilExit() } }
        func line(_ value: String) { try? FileHandle.standardOutput.write(contentsOf:Data((value + "\n").utf8)) }
        do {
            let request = try JSONDecoder().decode(H3WorkerRequest.self,from:H3Files.read(requestURL))
            let job = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(URL(fileURLWithPath:request.binding.jobPath)))
            guard request.binding.runtime.mode == .mock,request.binding.runtime.executable == URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path,
                  request.binding.appTaskID == request.appJobID,
                  job.profile.width == 768,job.profile.height == 448,job.profile.fps == 24,job.profile.steps == 4,
                  [73,90,124,141].contains(job.profile.frames),H3Supervisor.ownerPresent(request) else { throw StudioError.invalid("CPU 镜头 worker 不能执行真实绑定。") }
            let output = URL(fileURLWithPath:job.output_dir),raw = output.appendingPathComponent("record/lossless-frames"),ppm = output.appendingPathComponent("record/cpu-fixture-frames")
            _ = try H3Files.inside(output.path,request.binding.runtime.workDirectory + "/candidates")
            try FileManager.default.createDirectory(at:ppm,withIntermediateDirectories:false)
            let count = job.mock_scenario == "wrong_frames" ? job.profile.frames - 1 : job.profile.frames
            line("[STAGE] CPU 合成 S41 A/B 协议夹具；不使用 H3 或 GPU")
            for index in 0..<count {
                if abMockStop != 0 || !H3Supervisor.ownerPresent(request) { return 130 }
                if job.mock_scenario == "runner_failure" && index == 12 { line("[ERROR] CPU S41 fault injection");return 7 }
                let rgb = FixtureWorker.makeFrame(frame:Int(Double(index) * 47 / Double(max(1,count-1))),width:768,height:448)
                var bytes = Data("P6\n768 448\n255\n".utf8);bytes.append(rgb)
                try bytes.write(to:ppm.appendingPathComponent(String(format:"frame-%04d.ppm",index)),options:.withoutOverwriting)
                try FixtureWorker.savePNG(rgb,to:raw.appendingPathComponent(String(format:"frame-%04d.png",index)),width:768,height:448)
                line("[PROGRESS] \((index+1)*100/count)% of 'CPU fixture frame write' completed at now (\(index+1)/\(count))")
                if job.mock_scenario == "slow_generation" { Thread.sleep(forTimeInterval:0.12) }
            }
            if job.mock_scenario == "missing_output" { return 0 }
            line("[STAGE] 单线程 CPU 封装合成 MP4 与静音音轨")
            let process = Process();encoder = process;process.executableURL = URL(fileURLWithPath:request.ffmpeg)
            process.arguments = ["-hide_banner","-loglevel","error","-nostdin","-n","-threads","1","-filter_threads","1","-framerate","24","-i",ppm.path + "/frame-%04d.ppm","-f","lavfi","-i","anullsrc=r=48000:cl=stereo","-frames:v",String(count),"-t",String(Double(count)/24),"-c:v","libx264","-preset","ultrafast","-threads","1","-pix_fmt","yuv420p","-c:a","aac","-movflags","+faststart",job.clip_path]
            process.standardInput = FileHandle.nullDevice;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.standardError
            try process.run()
            while process.isRunning {
                if abMockStop != 0 || !H3Supervisor.ownerPresent(request) { process.terminate();process.waitUntilExit();return 130 }
                Thread.sleep(forTimeInterval:0.03)
            }
            guard process.terminationStatus == 0 else { throw StudioError.invalid("CPU S41 编码失败。") }
            if job.mock_scenario == "cancel_after_output" {
                line("[STAGE] CPU 候选已完整写出 · 等待取消测试")
                while abMockStop == 0 && H3Supervisor.ownerPresent(request) { Thread.sleep(forTimeInterval:0.05) }
                return 130
            }
            return 0
        } catch { line("[ERROR] " + error.localizedDescription);return 1 }
    }
}
