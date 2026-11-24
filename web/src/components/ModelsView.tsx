import React, { useState } from 'react';
import { Check, RefreshCw } from 'lucide-react';
import { useAppStore } from '../store/AppStore';
import type { ModelUnloadTimeout } from '../types';

function formatSize(mb: number): string {
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${Math.round(mb)} MB`;
}

export const ModelsView: React.FC = () => {
  const {
    settings,
    updateSettings,
    models,
    downloadProgress,
    selectModel,
    downloadModel,
    cancelModelDownload,
    deleteModel,
    rescanModels,
    t,
  } = useAppStore();

  const [unloadedNotice, setUnloadedNotice] = useState(false);

  return (
    <div className="space-y-12">
      {/* Local ASR Models Directory */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-3">
          <div className="space-y-1.5">
            <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
              {t('models.title')}
            </h3>
            <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
              {settings.app_language === 'zh'
                ? '本地离线语音识别模型。首次下载后完全在设备端运行，不上传录音。'
                : 'On-device offline ASR models. Once downloaded, transcription runs locally without uploading audio.'}
            </p>
          </div>
          <button
            type="button"
            onClick={rescanModels}
            className="btn-ghost h-8 px-3 text-[12px] flex items-center gap-1.5 cursor-pointer"
          >
            <RefreshCw className="w-3.5 h-3.5" />
            <span>{t('models.rescan')}</span>
          </button>
        </div>

        <div className="lg:col-span-8">
          <div className="border-y divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
            {models.map((model) => {
              const isActive = settings.selected_model === model.id;
              const progress = downloadProgress[model.id];

              return (
                <div
                  key={model.id}
                  className="flex items-center gap-3.5 py-4 px-2 -mx-2 transition-colors hover:bg-[var(--bg-hover)]"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  <button
                    type="button"
                    onClick={() => selectModel(model.id)}
                    className="w-4 h-4 shrink-0 border flex items-center justify-center cursor-pointer"
                    style={{
                      borderColor: isActive ? 'var(--accent)' : 'var(--border-strong)',
                      backgroundColor: isActive ? 'var(--accent)' : 'transparent',
                    }}
                    aria-label={model.name}
                  >
                    {isActive && <Check className="w-3 h-3 text-white" />}
                  </button>

                  <div
                    className="flex-1 min-w-0 cursor-pointer space-y-0.5"
                    onClick={() => selectModel(model.id)}
                  >
                    <div className="flex items-center gap-2 text-[14.5px] font-medium truncate">
                      <span>{model.name}</span>
                      {model.streaming && (
                        <span
                          className="text-[11px] font-mono-tabular uppercase"
                          style={{ color: 'var(--accent)' }}
                        >
                          · STREAMING
                        </span>
                      )}
                    </div>
                    <div
                      className="text-[12.5px] flex flex-wrap items-center gap-1.5"
                      style={{ color: 'var(--ink-secondary)' }}
                    >
                      <span className="font-mono-tabular">{formatSize(model.sizeMb)}</span>
                      <span aria-hidden="true">·</span>
                      <span>
                        {model.languages}{' '}
                        {settings.app_language === 'zh' ? '种语言' : 'languages'}
                      </span>
                      <span aria-hidden="true">·</span>
                      <span style={{ color: 'var(--ink-tertiary)' }}>{model.description}</span>
                    </div>
                  </div>

                  <div className="shrink-0 flex items-center gap-3">
                    {progress !== undefined ? (
                      <>
                        <div className="flex items-center gap-2">
                          <div
                            className="w-24 h-[3px] overflow-hidden"
                            style={{ backgroundColor: 'var(--border-hairline)' }}
                          >
                            <div
                              className="h-full transition-all"
                              style={{
                                width: `${Math.round(progress * 100)}%`,
                                backgroundColor: 'var(--accent)',
                              }}
                            />
                          </div>
                          <span
                            className="font-mono-tabular text-[11.5px] w-8 text-right"
                            style={{ color: 'var(--ink-secondary)' }}
                          >
                            {Math.round(progress * 100)}%
                          </span>
                        </div>
                        <button
                          type="button"
                          onClick={() => cancelModelDownload(model.id)}
                          className="text-[12.5px] hover:underline cursor-pointer"
                          style={{ color: 'var(--ink-secondary)' }}
                        >
                          {t('models.cancel')}
                        </button>
                      </>
                    ) : model.isDownloaded ? (
                      <button
                        type="button"
                        onClick={() => deleteModel(model.id)}
                        className="text-[12.5px] hover:underline cursor-pointer"
                        style={{ color: 'var(--status-err)' }}
                      >
                        {t('models.delete')}
                      </button>
                    ) : (
                      <button
                        type="button"
                        onClick={() => downloadModel(model.id)}
                        className="text-[12.5px] font-medium hover:underline cursor-pointer"
                        style={{ color: 'var(--accent)' }}
                      >
                        {t('models.download')}
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      {/* Acceleration & Memory Unload */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8 pb-4"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-1.5">
          <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
            {t('models.acceleration')}
          </h3>
          <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
            {settings.app_language === 'zh'
              ? '管理硬件推理后端与空闲时的模型内存释放策略。'
              : 'Configure hardware inference backends and automatic memory unloading.'}
          </p>
        </div>

        <div className="lg:col-span-8 divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
          <div className="pb-4 flex flex-wrap items-center justify-between gap-4">
            <label className="text-[14px]">{t('models.transcribeAcc')}</label>
            <select
              value={settings.transcribe_accelerator}
              onChange={(e) => updateSettings({ transcribe_accelerator: e.target.value })}
              className="studio-select min-w-[200px]"
            >
              <option value="auto">Auto</option>
              <option value="gpu">WebGPU / Metal</option>
              <option value="cpu">CPU</option>
            </select>
          </div>

          <div
            className="py-4 flex flex-wrap items-center justify-between gap-4"
            style={{ borderColor: 'var(--border-hairline)' }}
          >
            <label className="text-[14px]">{t('models.ortAcc')}</label>
            <select
              value={settings.ort_accelerator}
              onChange={(e) => updateSettings({ ort_accelerator: e.target.value })}
              className="studio-select min-w-[200px]"
            >
              <option value="auto">Auto</option>
              <option value="cpu">CPU</option>
              <option value="wasm">WebAssembly</option>
            </select>
          </div>

          <div
            className="py-4 flex flex-wrap items-center justify-between gap-4"
            style={{ borderColor: 'var(--border-hairline)' }}
          >
            <label className="text-[14px]">{t('models.unloadTimeout')}</label>
            <select
              value={settings.model_unload_timeout}
              onChange={(e) =>
                updateSettings({ model_unload_timeout: e.target.value as ModelUnloadTimeout })
              }
              className="studio-select min-w-[200px]"
            >
              <option value="immediately">Immediately</option>
              <option value="sec15">15 seconds</option>
              <option value="min2">2 minutes</option>
              <option value="min5">5 minutes</option>
              <option value="min10">10 minutes</option>
              <option value="min15">15 minutes</option>
              <option value="hour1">1 hour</option>
              <option value="never">Never</option>
            </select>
          </div>

          <div
            className="pt-4 flex items-center gap-3"
            style={{ borderColor: 'var(--border-hairline)' }}
          >
            <button
              type="button"
              onClick={() => {
                setUnloadedNotice(true);
                window.setTimeout(() => setUnloadedNotice(false), 2000);
              }}
              className="btn-ghost h-9 px-3.5 text-[12.5px] cursor-pointer"
            >
              {t('models.unloadNow')}
            </button>
            {unloadedNotice && (
              <span className="text-[12.5px]" style={{ color: 'var(--status-ok)' }}>
                {settings.app_language === 'zh'
                  ? '已释放当前模型内存'
                  : 'Model unloaded from memory'}
              </span>
            )}
          </div>
        </div>
      </section>
    </div>
  );
};
