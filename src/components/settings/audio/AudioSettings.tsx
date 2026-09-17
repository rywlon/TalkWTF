import React from "react";
import { useTranslation } from "react-i18next";
import { MicrophoneSelector } from "../MicrophoneSelector";
import { ChannelSelector } from "../ChannelSelector";
import { OutputDeviceSelector } from "../OutputDeviceSelector";
import { AudioFeedback } from "../AudioFeedback";
import { VolumeSlider } from "../VolumeSlider";
import { MuteWhileRecording } from "../MuteWhileRecording";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { useSettings } from "../../../hooks/useSettings";

export const AudioSettings: React.FC = () => {
  const { t } = useTranslation();
  const { audioFeedbackEnabled } = useSettings();

  return (
    <div className="max-w-[880px] w-full mx-auto space-y-6">
      <SettingsGroup title={t("settings.sound.title")}>
        <MicrophoneSelector descriptionMode="tooltip" grouped={true} />
        <ChannelSelector descriptionMode="tooltip" grouped={true} />
        <MuteWhileRecording descriptionMode="tooltip" grouped={true} />
        <AudioFeedback descriptionMode="tooltip" grouped={true} />
        <OutputDeviceSelector
          descriptionMode="tooltip"
          grouped={true}
          disabled={!audioFeedbackEnabled}
        />
        <VolumeSlider disabled={!audioFeedbackEnabled} />
      </SettingsGroup>
    </div>
  );
};
