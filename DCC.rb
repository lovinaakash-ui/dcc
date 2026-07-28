require 'sketchup.rb'
require 'extensions.rb'

module AJ
  module DynamicCabinetCreator
    
    unless file_loaded?(__FILE__)
      # Create extension
      ex = SketchupExtension.new('Dynamic Cabinet Creator', 'DCC/main')
      ex.description = 'Create and modify modular cabinets dynamically within SketchUp'
      ex.version     = '1.0.0'
      ex.copyright   = '2024 AJ'
      ex.creator     = 'AJ'
      
      # Register extension
      Sketchup.register_extension(ex, true)
      
      file_loaded(__FILE__)
    end
    
  end
end

