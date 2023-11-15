#
# Be sure to run `pod lib lint KcDebugTool.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'KcDebugTool'
  s.version          = '0.1.3'
  s.summary          = 'A short description of KcDebugTool.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/zhangjie579'
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { '张杰' => '527512749@qq.com' }
  s.source           = { :git => 'https://github.com/zhangjie579/KcDebugTool.git', :tag => s.version.to_s }
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'

  s.ios.deployment_target = '9.0'
  s.swift_version = "5.0"

#  s.source_files = 'KcDebugTool/Classes/**/*'
  
  # s.resource_bundles = {
  #   'KcDebugTool' => ['KcDebugTool/Assets/*.png']
  # }

  # s.public_header_files = 'Pod/Classes/**/*.h'
  # s.frameworks = 'UIKit', 'MapKit'
  # s.dependency 'AFNetworking', '~> 2.3'
  
  s.subspec 'View' do |v|
      v.source_files = 'KcDebugTool/Classes/View/**/*'
      v.frameworks = 'UIKit'
      v.dependency "KcDebugSwift/FindProperty"
#      m.dependency 'KcDebugTool/SDK'
  end
  
  # 基础库
  s.subspec 'sdk' do |ss|
      ss.source_files = 'KcDebugTool/Classes/sdk/**/*'
      ss.frameworks = 'UIKit'
  end
  
  # 用于hook
  s.subspec 'model' do |m|
      m.source_files = 'KcDebugTool/Classes/model/**/*'
      m.frameworks = 'UIKit'
      m.dependency 'KcDebugTool/sdk'
#      m.dependency 'TrampolineHook'
  end
  
  # 一些工具
  s.subspec 'other' do |ss|
      ss.source_files = 'KcDebugTool/Classes/other/**/*'
      ss.frameworks = 'UIKit'
      ss.dependency 'KcDebugTool/sdk'
      ss.dependency 'KcDebugTool/model'
      ss.dependency "KcDebugSwift/FindProperty"
      
      ss.dependency "fishhook"
  end
  
  s.subspec 'extension' do |ss|
      ss.source_files = 'KcDebugTool/Classes/extension/**/*'
      ss.frameworks = 'UIKit'
      ss.dependency 'KcDebugTool/model'
      ss.dependency 'KcDebugTool/autoLayout'
#      m.dependency 'TrampolineHook'
  end
  
  s.subspec 'MachO' do |ss|
      ss.source_files = 'KcDebugTool/Classes/MachO/**/*'
      ss.dependency 'KcDebugTool/extension'
  end
  
  # 约束相关
  s.subspec 'autoLayout' do |ss|
      ss.source_files = 'KcDebugTool/Classes/autoLayout/**/*'
      ss.dependency 'KcDebugTool/model'
      ss.dependency "KcDebugSwift/FindProperty"
  end
  
  # 全部依赖了
  s.subspec 'DebugTool' do |d|
      d.source_files = 'KcDebugTool/Classes/DebugTool/**/*'
      d.frameworks = 'UIKit'
      d.dependency 'KcDebugTool/extension'
      d.dependency 'KcDebugTool/other'
      d.dependency 'KcDebugTool/View'
      d.dependency 'KcDebugTool/MachO'
      d.dependency 'KcDebugTool/autoLayout'
#      m.dependency 'TrampolineHook'
  end
  
  s.subspec 'lldb' do |ss|
      ss.source_files = 'KcDebugTool/Classes/lldb/**/*'
      ss.frameworks = 'UIKit'
  end
  
  s.subspec 'zombieTool' do |ss|
      ss.source_files = 'KcDebugTool/Classes/zombieTool/**/*'
  end
  
  s.subspec 'zombieMRC' do |ss|
      ss.requires_arc = false # 默认为MRC
      ss.source_files = 'KcDebugTool/Classes/zombieMRC/**/*'
      ss.dependency 'KcDebugTool/zombieTool'
  end
  
  # MARK: - Zombie 野指针
  # s.subspec 'Zombie' do |ss|
  #     ss.libraries = "z", "c++"
      
  #     ss.requires_arc = false # 默认为MRC
  #     ss.source_files = 'KcDebugTool/Classes/Zombie/**/*'
  #     ss.requires_arc = 'KcDebugTool/Classes/Zombie/ARC/**/*' # ARC的文件
      
  #     # 把.mm相关的头文件过滤, 为了兼容swift (不会出现在umbrella.h文件内)
  #     # 不能加[], 多个用, 分割
  #     ss.private_header_files = 'KcTestZoobie/Classes/Zombie/DDZombie.h', 'KcDebugTool/Classes/Zombie/ARC/DDThreadStack.h'
  # end

end
