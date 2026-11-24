import React, { useState } from 'react';
import { Check, Plus, RotateCcw, X } from 'lucide-react';
import { POLISH_STYLES, TRANSLATION_LANGUAGES } from '../data/defaults';
import { useAppStore } from '../store/AppStore';
import type { Scene } from '../types';
import { TactileSwitch } from './ui/Controls';

export const PersonalizationView: React.FC = () => {
  const {
    settings,
    updateSettings,
    addScene,
    updateScene,
    deleteScene,
    restoreBuiltInScenes,
    setActiveScene,
    addTranslationTarget,
    removeTranslationTarget,
    setActiveTranslationTarget,
    t,
  } = useAppStore();

  const [editingScene, setEditingScene] = useState<Partial<Scene> | null>(null);

  const currentProvider = settings.post_process_providers.find(
    (p) => p.id === settings.post_process_provider_id,
  );
  const availableLanguages = TRANSLATION_LANGUAGES.filter(
    (l) => !settings.translation_targets.includes(l.value),
  );

  const updateProviderBaseUrl = (url: string) => {
    const next = settings.post_process_providers.map((p) =>
      p.id === settings.post_process_provider_id ? { ...p, base_url: url } : p,
    );
    updateSettings({ post_process_providers: next });
  };

  return (
    <div className="space-y-12">
      {/* AI Polish Provider */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-1.5">
          <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
            {t('sidebar.postProcessing')}
          </h3>
          <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
            {t('personalization.envNotice')}
          </p>
        </div>

        <div className="lg:col-span-8 divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
          <div className="pb-4 flex flex-wrap items-center justify-between gap-4">
            <label className="text-[14px]">{t('personalization.provider')}</label>
            <select
              value={settings.post_process_provider_id}
              onChange={(e) => updateSettings({ post_process_provider_id: e.target.value })}
              className="studio-select min-w-[220px]"
            >
              <option value="">{t('personalization.noScene')}</option>
              {settings.post_process_providers.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.label}
                </option>
              ))}
            </select>
          </div>

          {currentProvider && (
            <>
              <div
                className="py-4 flex flex-wrap items-center justify-between gap-4"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <label className="text-[14px]">{t('personalization.baseUrl')}</label>
                <input
                  type="text"
                  value={currentProvider.base_url}
                  disabled={!currentProvider.allow_base_url_edit}
                  onChange={(e) => updateProviderBaseUrl(e.target.value)}
                  className="studio-input font-mono-tabular text-[12.5px] w-full sm:w-[320px] disabled:opacity-55"
                />
              </div>

              <div
                className="py-4 flex flex-wrap items-center justify-between gap-4"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <label className="text-[14px]">{t('personalization.model')}</label>
                <input
                  type="text"
                  value={settings.post_process_models[currentProvider.id] ?? ''}
                  onChange={(e) =>
                    updateSettings({
                      post_process_models: {
                        ...settings.post_process_models,
                        [currentProvider.id]: e.target.value,
                      },
                    })
                  }
                  className="studio-input font-mono-tabular text-[13px] w-full sm:w-[320px]"
                />
              </div>

              <div
                className="pt-4 flex items-center justify-between gap-4"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <label className="text-[14px]">{t('personalization.thinking')}</label>
                <TactileSwitch
                  checked={settings.post_process_thinking}
                  onChange={(next) => updateSettings({ post_process_thinking: next })}
                  ariaLabel={t('personalization.thinking')}
                />
              </div>
            </>
          )}
        </div>
      </section>

      {/* Polish Style: Sharp 4-Column Hairline Grid */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-1.5">
          <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
            {t('personalization.style')}
          </h3>
          <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
            {settings.app_language === 'zh'
              ? '控制口语转书面语的润色力度，无需手写提示词。'
              : 'Control how strongly spoken transcripts are reshaped without writing prompts.'}
          </p>
        </div>

        <div className="lg:col-span-8">
          <div
            className="grid grid-cols-1 sm:grid-cols-2 border-t border-l"
            style={{ borderColor: 'var(--border-hairline)' }}
          >
            {POLISH_STYLES.map((style) => {
              const active = settings.polish_style === style.value;
              return (
                <button
                  key={style.value}
                  type="button"
                  onClick={() => updateSettings({ polish_style: style.value })}
                  className="relative p-4 text-left border-r border-b transition-colors cursor-pointer hover:bg-[var(--bg-hover)]"
                  style={{
                    borderColor: 'var(--border-hairline)',
                    backgroundColor: active ? 'var(--accent-soft)' : 'transparent',
                  }}
                >
                  {active && (
                    <span
                      className="absolute left-0 right-0 top-0 h-[2px]"
                      style={{ backgroundColor: 'var(--accent)' }}
                    />
                  )}
                  <div className="flex items-center justify-between gap-2 mb-1">
                    <span className="text-[14px] font-semibold">{style.label}</span>
                    {active && <Check className="w-3.5 h-3.5" style={{ color: 'var(--accent)' }} />}
                  </div>
                  <p className="text-[12px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
                    {style.description}
                  </p>
                </button>
              );
            })}
          </div>
        </div>
      </section>

      {/* Scenes */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-3">
          <div className="space-y-1.5">
            <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
              {t('personalization.scenes')}
            </h3>
            <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
              {t('personalization.scenesHint')}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2 pt-1">
            <button
              type="button"
              onClick={() => setEditingScene({ name: '', description: '', prompt: '' })}
              className="btn-accent h-8 px-3 text-[12px] flex items-center gap-1.5 cursor-pointer"
            >
              <Plus className="w-3.5 h-3.5" />
              <span>{t('personalization.newScene')}</span>
            </button>
            <button
              type="button"
              onClick={restoreBuiltInScenes}
              className="btn-ghost h-8 px-3 text-[12px] flex items-center gap-1.5 cursor-pointer"
            >
              <RotateCcw className="w-3 h-3" />
              <span>{t('personalization.restoreBuiltIn')}</span>
            </button>
          </div>
        </div>

        <div className="lg:col-span-8">
          <div className="border-y divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
            {settings.scenes.map((scene) => {
              const active = settings.active_scene_id === scene.id;
              const isBuiltIn = scene.id.startsWith('builtin_');
              return (
                <div
                  key={scene.id}
                  className="flex items-center gap-3.5 py-3.5 px-2 -mx-2 transition-colors hover:bg-[var(--bg-hover)]"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  <button
                    type="button"
                    onClick={() => setActiveScene(active ? null : scene.id)}
                    className="w-4 h-4 shrink-0 border flex items-center justify-center cursor-pointer"
                    style={{
                      borderColor: active ? 'var(--accent)' : 'var(--border-strong)',
                      backgroundColor: active ? 'var(--accent)' : 'transparent',
                    }}
                    aria-label={scene.name}
                  >
                    {active && <Check className="w-3 h-3 text-white" />}
                  </button>

                  <div
                    className="flex-1 min-w-0 cursor-pointer"
                    onClick={() => setActiveScene(active ? null : scene.id)}
                  >
                    <div className="text-[14px] font-medium flex items-center gap-2">
                      <span>{scene.name}</span>
                      {active && (
                        <span
                          className="text-[11px] font-mono-tabular"
                          style={{ color: 'var(--accent)' }}
                        >
                          ACTIVE
                        </span>
                      )}
                    </div>
                    {scene.description && (
                      <div className="text-[12.5px] truncate" style={{ color: 'var(--ink-secondary)' }}>
                        {scene.description}
                      </div>
                    )}
                  </div>

                  <div className="flex items-center gap-3 text-[12.5px] shrink-0">
                    <button
                      type="button"
                      onClick={() => setEditingScene(scene)}
                      className="hover:underline cursor-pointer"
                      style={{ color: 'var(--ink-secondary)' }}
                    >
                      {t('common.edit')}
                    </button>
                    {!isBuiltIn && (
                      <button
                        type="button"
                        onClick={() => deleteScene(scene.id)}
                        className="hover:underline cursor-pointer"
                        style={{ color: 'var(--status-err)' }}
                      >
                        {t('common.delete')}
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {settings.active_scene_id && (
            <button
              type="button"
              onClick={() => setActiveScene(null)}
              className="mt-3 text-[12.5px] hover:underline cursor-pointer"
              style={{ color: 'var(--ink-secondary)' }}
            >
              {t('personalization.noScene')}
            </button>
          )}
        </div>
      </section>

      {/* Translation Targets */}
      <section
        className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8 pb-4"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <div className="lg:col-span-4 space-y-1.5">
          <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
            {t('personalization.translation')}
          </h3>
          <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
            {t('personalization.translationHint')}
          </p>
        </div>

        <div className="lg:col-span-8 space-y-4">
          <div className="border-y divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
            {settings.translation_targets.map((code) => {
              const label = TRANSLATION_LANGUAGES.find((l) => l.value === code)?.label ?? code;
              const active = settings.translation_active_target === code;
              return (
                <div
                  key={code}
                  className="flex items-center gap-3.5 py-3"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  <button
                    type="button"
                    onClick={() => setActiveTranslationTarget(code)}
                    className="w-4 h-4 shrink-0 border flex items-center justify-center cursor-pointer"
                    style={{
                      borderColor: active ? 'var(--accent)' : 'var(--border-strong)',
                      backgroundColor: active ? 'var(--accent)' : 'transparent',
                    }}
                    aria-label={label}
                  >
                    {active && <Check className="w-3 h-3 text-white" />}
                  </button>
                  <button
                    type="button"
                    onClick={() => setActiveTranslationTarget(code)}
                    className="text-[14px] flex-1 text-left cursor-pointer"
                  >
                    <span>{label}</span>
                    <span
                      className="ml-2 text-[11.5px] font-mono-tabular uppercase"
                      style={{ color: 'var(--ink-tertiary)' }}
                    >
                      {code}
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => removeTranslationTarget(code)}
                    className="text-[12.5px] hover:underline cursor-pointer"
                    style={{ color: 'var(--status-err)' }}
                  >
                    {t('common.delete')}
                  </button>
                </div>
              );
            })}
          </div>

          {settings.translation_targets.length < 3 && (
            <select
              value=""
              onChange={(e) => {
                if (e.target.value) addTranslationTarget(e.target.value);
              }}
              className="studio-select w-[240px]"
            >
              <option value="">{t('personalization.addTarget')}</option>
              {availableLanguages.map((lang) => (
                <option key={lang.value} value={lang.value}>
                  {lang.label}
                </option>
              ))}
            </select>
          )}
        </div>
      </section>

      {editingScene && (
        <SceneEditorModal
          draft={editingScene}
          onClose={() => setEditingScene(null)}
          onSave={(saved) => {
            if (editingScene.id) {
              updateScene(editingScene.id, saved);
            } else {
              addScene(saved);
            }
            setEditingScene(null);
          }}
        />
      )}
    </div>
  );
};

const SceneEditorModal: React.FC<{
  draft: Partial<Scene>;
  onClose: () => void;
  onSave: (val: Pick<Scene, 'name' | 'description' | 'prompt'>) => void;
}> = ({ draft, onClose, onSave }) => {
  const { t } = useAppStore();
  const [name, setName] = useState(draft.name ?? '');
  const [description, setDescription] = useState(draft.description ?? '');
  const [prompt, setPrompt] = useState(draft.prompt ?? '');

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/55 backdrop-blur-[3px] p-4">
      <div
        className="w-full max-w-[500px] studio-panel p-6 shadow-2xl space-y-5"
        style={{ borderColor: 'var(--border-strong)' }}
      >
        <div className="flex items-center justify-between">
          <h3 className="font-display text-[19px] font-semibold">
            {draft.id ? t('common.edit') : t('personalization.newScene')}
          </h3>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 hover:bg-[var(--bg-hover)] cursor-pointer"
            style={{ color: 'var(--ink-secondary)' }}
            aria-label="Close"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <div className="space-y-4">
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="场景名称"
            className="studio-input w-full"
            autoFocus
          />
          <input
            type="text"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="简短描述"
            className="studio-input w-full"
          />
          <textarea
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            rows={6}
            placeholder="Scene prompt instructions..."
            className="studio-textarea w-full font-mono-tabular text-[12.5px] resize-none leading-relaxed"
          />
        </div>

        <div className="flex justify-end gap-2 pt-1">
          <button
            type="button"
            onClick={onClose}
            className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
          >
            {t('common.cancel')}
          </button>
          <button
            type="button"
            disabled={!name.trim()}
            onClick={() => onSave({ name, description, prompt })}
            className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
          >
            {t('common.save')}
          </button>
        </div>
      </div>
    </div>
  );
};
