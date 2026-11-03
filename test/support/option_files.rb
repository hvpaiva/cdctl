# frozen_string_literal: true

# A made-up file with the same shape as the one the game writes.
module OptionFiles
  module_function

  def sample(viewport: nil, preset: 'A', hud_scale: 90, upscale: '67%')
    viewport_line = viewport ? %(<OptionInt2Vector Name="_viewportSize" _value="#{viewport}"/>) : ''
    <<~XML
      <EngineOptionSave ReflectObjectXMLDataVersion="9" _selectPreset="Custom">
        <EngineOption Name="_option" Template="/Default.engineoption">
          <EngineOptionVideo Name="_videoOption">
            <OptionInt Name="_uiHudScale" _value="#{hud_scale}"/>
          </EngineOptionVideo>
          <EngineOptionResolution Name="_resolutionOption">
            #{viewport_line}
            <EnumSelectResolutionScale Name="_upscaleResolution" _select="#{upscale}">
              <Vector Name="_modeGroup" isOverrided="false">
                <EnumOptionResolutionScale _mode="AA" _localStr="Native"/>
              </Vector>
            </EnumSelectResolutionScale>
          </EngineOptionResolution>
          <EngineOptionControls Name="_controlsOption">
            <EnumSelectKeyboardMousePresetOptionType Name="_keyboardMousePresetOptionType" _select="#{preset}"/>
          </EngineOptionControls>
        </EngineOption>
      </EngineOptionSave>
    XML
  end
end
