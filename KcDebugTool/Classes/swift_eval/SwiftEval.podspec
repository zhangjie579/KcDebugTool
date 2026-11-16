Pod::Spec.new do |s|
  s.name             = 'SwiftEval'
  s.version          = '0.1.0'
  s.summary          = '运行时受限 Swift 表达式求值（真机调试工具）'
  s.description      = <<-DESC
解析 Type.method(args) 形式的受限 Swift 表达式，通过 Mach-O 符号和 Swift ABI
调用类方法 / 实例方法，并保留任意类型的返回值（可读文本 + JSON）。仅用于 DEBUG 调试。
                       DESC
  s.homepage         = 'https://gitlab.badambiz.com/weiyu-ios/sawa'
  s.license          = { :type => 'MIT', :text => 'Internal debug tool, not for distribution.' }
  s.author           = { 'Sawa iOS' => '' }
  s.source           = { :git => 'git@gitlab.badambiz.com:weiyu-ios/sawa.git', :tag => s.version.to_s }

  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '11.0'
  s.swift_version = '5.6'
  s.requires_arc = true

  s.source_files = 'Classes/**/*.{swift,h,m,S}'
  s.public_header_files = 'Classes/**/*.h'
  s.resource_bundles = {
    'SwiftEvalResources' => ['Resources/*.html']
  }
  s.frameworks = 'Foundation'
end
