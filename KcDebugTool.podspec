#
# Be sure to run `pod lib lint KcDebugTool.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'KcDebugTool'
  s.version          = '0.0.1'
  s.summary          = 'A short description of KcDebugTool.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://code.badam.mobi/zhangjie/kcdebugtool.git'
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { '张杰' => '527512749@qq.com' }
  s.source           = { :git => 'https://code.badam.mobi/zhangjie/kcdebugtool.git', :tag => s.version.to_s }
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'

  s.ios.deployment_target = '8.0'

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
#      m.dependency 'KcDebugTool/SDK'
  end
  
  s.subspec 'other' do |other|
      other.source_files = 'KcDebugTool/Classes/other/**/*'
      other.frameworks = 'UIKit'
  end
  
  s.subspec 'sdk' do |sdk|
      sdk.source_files = 'KcDebugTool/Classes/sdk/**/*'
      sdk.frameworks = 'UIKit'
  end
  
  s.subspec 'model' do |m|
      m.source_files = 'KcDebugTool/Classes/model/**/*'
      m.frameworks = 'UIKit'
      m.dependency 'KcDebugTool/sdk'
#      m.dependency 'TrampolineHook'
  end
  
  s.subspec 'extension' do |e|
      e.source_files = 'KcDebugTool/Classes/extension/**/*'
      e.frameworks = 'UIKit'
      e.dependency 'KcDebugTool/model'
#      m.dependency 'TrampolineHook'
  end
  
  # 全部依赖了
  s.subspec 'DebugTool' do |d|
      d.source_files = 'KcDebugTool/Classes/DebugTool/**/*'
      d.frameworks = 'UIKit'
      d.dependency 'KcDebugTool/extension'
      d.dependency 'KcDebugTool/other'
      d.dependency 'KcDebugTool/View'
#      m.dependency 'TrampolineHook'
  end

end
