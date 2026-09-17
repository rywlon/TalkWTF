import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { ChevronDown, ChevronRight, Plus, RotateCcw } from "lucide-react";
import { toast } from "sonner";
import { open, save } from "@tauri-apps/plugin-dialog";
import { commands, type Scene } from "@/bindings";

import { Alert } from "../../ui/Alert";
import { Button } from "../../ui/Button";
import {
  Dropdown,
  SettingContainer,
  SettingsGroup,
  Textarea,
} from "@/components/ui";
import { Input } from "../../ui/Input";
import { useSettings } from "../../../hooks/useSettings";

const BUILT_IN_SCENE_PREFIX = "builtin_";
const NO_SCENE = "";

type SceneDraft = {
  id: string | null;
  name: string;
  description: string;
  prompt: string;
};

const isBuiltIn = (scene: Scene) => scene.id.startsWith(BUILT_IN_SCENE_PREFIX);

const draftFrom = (scene: Scene): SceneDraft => ({
  id: scene.id,
  name: scene.name,
  description: scene.description ?? "",
  prompt: scene.prompt,
});

const SceneEditor: React.FC<{
  draft: SceneDraft;
  onChange: (draft: SceneDraft) => void;
  onSave: () => void;
  onCancel: () => void;
  isSaving: boolean;
}> = ({ draft, onChange, onSave, onCancel, isSaving }) => {
  const { t } = useTranslation();
  const canSave = draft.name.trim() !== "" && draft.prompt.trim() !== "";

  return (
    <div className="space-y-3 rounded-md border border-mid-gray/20 p-3">
      <div className="space-y-2 flex flex-col">
        <label className="text-sm font-semibold">
          {t("settings.postProcessing.prompts.promptLabel")}
        </label>
        <Input
          type="text"
          value={draft.name}
          onChange={(event) => onChange({ ...draft, name: event.target.value })}
          placeholder={t(
            "settings.postProcessing.prompts.promptLabelPlaceholder",
          )}
          variant="compact"
        />
      </div>

      <div className="space-y-2 flex flex-col">
        <label className="text-sm font-semibold">
          {t("settings.postProcessing.prompts.promptInstructions")}
        </label>
        <Textarea
          value={draft.prompt}
          onChange={(event) =>
            onChange({ ...draft, prompt: event.target.value })
          }
          placeholder={t(
            "settings.postProcessing.prompts.promptInstructionsPlaceholder",
          )}
        />
        <p className="text-xs text-mid-gray/70">
          {t("settings.postProcessing.prompts.promptTip")}
        </p>
      </div>

      <div className="flex gap-2 pt-1">
        <Button
          onClick={onSave}
          variant="secondary"
          size="md"
          disabled={!canSave || isSaving}
        >
          {draft.id
            ? t("settings.postProcessing.prompts.updatePrompt")
            : t("settings.postProcessing.prompts.createPrompt")}
        </Button>
        <Button onClick={onCancel} variant="secondary" size="md">
          {t("settings.postProcessing.prompts.cancel")}
        </Button>
      </div>
    </div>
  );
};

const SceneCard: React.FC<{
  scene: Scene;
  isActive: boolean;
  isExpanded: boolean;
  isConfirmingDelete: boolean;
  onToggleExpand: () => void;
  onActivate: () => void;
  onEdit: () => void;
  onDuplicate: () => void;
  onDelete: () => void;
  onConfirmDelete: () => void;
  onReset: () => void;
}> = ({
  scene,
  isActive,
  isExpanded,
  isConfirmingDelete,
  onToggleExpand,
  onActivate,
  onEdit,
  onDuplicate,
  onDelete,
  onConfirmDelete,
  onReset,
}) => {
  const { t } = useTranslation();
  const builtIn = isBuiltIn(scene);

  return (
    <div
      className={`rounded-md border border-mid-gray/20 bg-mid-gray/5 ${
        isActive ? "border-l-2 border-l-text" : ""
      }`}
    >
      <div className="flex items-start gap-2 p-3">
        <button
          type="button"
          onClick={onToggleExpand}
          className="mt-0.5 text-mid-gray hover:text-text"
          aria-label="Toggle scene details"
        >
          {isExpanded ? (
            <ChevronDown className="h-4 w-4" />
          ) : (
            <ChevronRight className="h-4 w-4" />
          )}
        </button>

        <div className="min-w-0 flex-1">
          <span className="truncate text-sm font-medium">{scene.name}</span>
          {scene.description && (
            <p className="mt-0.5 text-xs text-mid-gray">{scene.description}</p>
          )}

          {isExpanded && (
            <pre className="mt-2 max-h-48 overflow-y-auto whitespace-pre-wrap break-words rounded border border-mid-gray/20 bg-background p-2 font-mono text-xs text-mid-gray">
              {scene.prompt}
            </pre>
          )}

          <div className="mt-2 flex flex-wrap gap-2">
            {!isActive && (
              <Button onClick={onActivate} variant="secondary" size="sm">
                {t("settings.postProcessing.prompts.selectPrompt")}
              </Button>
            )}
            <Button onClick={onEdit} variant="secondary" size="sm">
              {t("settings.postProcessing.scene.edit")}
            </Button>
            <Button onClick={onDuplicate} variant="secondary" size="sm">
              {t("settings.postProcessing.prompts.duplicate")}
            </Button>
            {builtIn && (
              <Button onClick={onReset} variant="secondary" size="sm">
                {t("settings.postProcessing.prompts.restoreDefault")}
              </Button>
            )}
            {isConfirmingDelete ? (
              <Button onClick={onDelete} variant="danger-ghost" size="sm">
                {t("settings.postProcessing.scene.confirmDelete")}
              </Button>
            ) : (
              <Button onClick={onConfirmDelete} variant="secondary" size="sm">
                {t("settings.postProcessing.prompts.deletePrompt")}
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export const StyleAndScenesPane: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, refreshSettings } = useSettings();

  const scenes = getSetting("scenes") ?? [];
  const activeSceneId = getSetting("active_scene_id") ?? NO_SCENE;
  const polishStyle = getSetting("polish_style") ?? "clean";

  const [styleOptions, setStyleOptions] = useState<
    { value: string; label: string }[]
  >([]);
  const [draft, setDraft] = useState<SceneDraft | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    void commands.getPolishStyles().then((styles) => setStyleOptions(styles));
  }, []);

  const builtInScenes = scenes.filter(isBuiltIn);
  const customScenes = scenes.filter((scene) => !isBuiltIn(scene));
  const activeScene = scenes.find((scene) => scene.id === activeSceneId);

  const handleActiveSceneSelect = async (value: string) => {
    try {
      await commands.setActiveScene(value === NO_SCENE ? null : value);
      await refreshSettings();
    } catch (error) {
      console.error("Failed to set the active scene:", error);
    }
  };

  const uniqueName = (base: string) => {
    const taken = new Set(scenes.map((scene) => scene.name));
    let suffix = 2;
    let name = `${base} (${suffix})`;
    while (taken.has(name)) {
      suffix += 1;
      name = `${base} (${suffix})`;
    }
    return name;
  };

  const handleSave = async () => {
    if (!draft) return;
    setIsSaving(true);

    try {
      const result = draft.id
        ? await commands.updateScene(
            draft.id,
            draft.name,
            draft.description,
            draft.prompt,
          )
        : await commands.addScene(draft.name, draft.description, draft.prompt);

      if (result.status === "error") {
        toast.error(result.error);
        return;
      }

      await refreshSettings();
      setDraft(null);
    } catch (error) {
      console.error("Failed to save the scene:", error);
    } finally {
      setIsSaving(false);
    }
  };

  const handleDuplicate = async (scene: Scene) => {
    try {
      const result = await commands.addScene(
        uniqueName(scene.name),
        scene.description ?? "",
        scene.prompt,
      );
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      await refreshSettings();
    } catch (error) {
      console.error("Failed to duplicate the scene:", error);
    }
  };

  const handleDelete = async (id: string) => {
    try {
      const result = await commands.deleteScene(id);
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      setConfirmDeleteId(null);
      await refreshSettings();
    } catch (error) {
      console.error("Failed to delete the scene:", error);
    }
  };

  const handleReset = async (id: string) => {
    try {
      const result = await commands.resetScene(id);
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      await refreshSettings();
    } catch (error) {
      console.error("Failed to reset the scene:", error);
    }
  };

  const handleExportProfile = async () => {
    try {
      const path = await save({
        defaultPath: "talkwtf-polish-profile.json",
        filters: [{ name: "JSON", extensions: ["json"] }],
      });
      if (!path) return;

      const result = await commands.exportPolishProfile(path);
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      toast.success(t("settings.postProcessing.scene.exportDone"));
    } catch (error) {
      console.error("Failed to export the polish profile:", error);
    }
  };

  const handleImportProfile = async () => {
    try {
      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "JSON", extensions: ["json"] }],
      });
      if (typeof path !== "string") return;

      const result = await commands.importPolishProfile(path);
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      toast.success(
        t("settings.postProcessing.scene.importReport", {
          accepted: result.data.accepted,
          duplicates: result.data.skipped_duplicates,
          invalid: result.data.skipped_invalid,
        }),
      );
      await refreshSettings();
    } catch (error) {
      console.error("Failed to import the polish profile:", error);
    }
  };

  const handleRestoreBuiltIns = async () => {
    try {
      const result = await commands.restoreBuiltInScenes();
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      await refreshSettings();
    } catch (error) {
      console.error("Failed to restore the built-in scenes:", error);
    }
  };

  const renderScenes = (list: Scene[]) =>
    list.map((scene) => (
      <SceneCard
        key={scene.id}
        scene={scene}
        isActive={scene.id === activeSceneId}
        isExpanded={expandedId === scene.id}
        isConfirmingDelete={confirmDeleteId === scene.id}
        onToggleExpand={() =>
          setExpandedId((current) => (current === scene.id ? null : scene.id))
        }
        onActivate={() => void handleActiveSceneSelect(scene.id)}
        onEdit={() => {
          setConfirmDeleteId(null);
          setDraft(draftFrom(scene));
        }}
        onDuplicate={() => void handleDuplicate(scene)}
        onDelete={() => void handleDelete(scene.id)}
        onConfirmDelete={() => setConfirmDeleteId(scene.id)}
        onReset={() => void handleReset(scene.id)}
      />
    ));

  return (
    <>
      <SettingsGroup title={t("settings.postProcessing.style.title")}>
        <SettingContainer
          title={t("settings.postProcessing.style.title")}
          description={t("settings.postProcessing.style.description")}
          descriptionMode="tooltip"
          layout="horizontal"
          grouped={true}
        >
          <Dropdown
            selectedValue={polishStyle}
            options={styleOptions}
            onSelect={(value) => void updateSetting("polish_style", value)}
            className="min-w-[220px]"
          />
        </SettingContainer>

        {activeScene && (
          <Alert variant="info" contained>
            {t("settings.postProcessing.scene.styleSkipped", {
              name: activeScene.name,
            })}
          </Alert>
        )}
      </SettingsGroup>

      <SettingsGroup title={t("settings.postProcessing.scene.title")}>
        <SettingContainer
          title={t("settings.postProcessing.scene.title")}
          description={t("settings.postProcessing.scene.description")}
          descriptionMode="tooltip"
          layout="horizontal"
          grouped={true}
        >
          <Dropdown
            selectedValue={activeSceneId}
            options={[
              {
                value: NO_SCENE,
                label: t("settings.postProcessing.scene.none"),
              },
              ...scenes.map((scene) => ({
                value: scene.id,
                label: scene.name,
              })),
            ]}
            onSelect={(value) => void handleActiveSceneSelect(value)}
            className="min-w-[260px]"
          />
        </SettingContainer>
        <div className="flex gap-2 px-1">
          <Button
            onClick={() => void handleExportProfile()}
            variant="secondary"
            size="md"
          >
            {t("settings.postProcessing.scene.export")}
          </Button>
          <Button
            onClick={() => void handleImportProfile()}
            variant="secondary"
            size="md"
          >
            {t("settings.postProcessing.scene.import")}
          </Button>
        </div>
      </SettingsGroup>

      <SettingsGroup
        title={t("settings.postProcessing.prompts.selectedPrompt.title")}
      >
        <SettingContainer
          title={t("settings.postProcessing.prompts.selectedPrompt.title")}
          description={t(
            "settings.postProcessing.prompts.selectedPrompt.description",
          )}
          descriptionMode="tooltip"
          layout="stacked"
          grouped={true}
        >
          <div className="space-y-3">
            <div className="flex flex-wrap gap-2">
              <Button
                onClick={() => {
                  setConfirmDeleteId(null);
                  setDraft({ id: null, name: "", description: "", prompt: "" });
                }}
                variant="secondary"
                size="md"
                disabled={draft !== null && draft.id === null}
              >
                <span className="flex items-center gap-1">
                  <Plus className="h-4 w-4" />
                  {t("settings.postProcessing.prompts.createNew")}
                </span>
              </Button>
            </div>

            {draft && draft.id === null && (
              <SceneEditor
                draft={draft}
                onChange={setDraft}
                onSave={() => void handleSave()}
                onCancel={() => setDraft(null)}
                isSaving={isSaving}
              />
            )}

            {customScenes.length === 0 && !draft && (
              <div className="rounded-md border border-mid-gray/20 bg-mid-gray/5 p-3">
                <p className="text-sm text-mid-gray">
                  {t("settings.postProcessing.prompts.createFirst")}
                </p>
              </div>
            )}

            {renderScenes(customScenes)}

            {draft && draft.id !== null && (
              <SceneEditor
                draft={draft}
                onChange={setDraft}
                onSave={() => void handleSave()}
                onCancel={() => setDraft(null)}
                isSaving={isSaving}
              />
            )}
          </div>
        </SettingContainer>
      </SettingsGroup>

      <SettingsGroup title={t("settings.postProcessing.scene.builtInTitle")}>
        <SettingContainer
          title={t("settings.postProcessing.scene.builtInTitle")}
          description={t("settings.postProcessing.scene.builtInDescription")}
          descriptionMode="tooltip"
          layout="stacked"
          grouped={true}
        >
          <div className="space-y-3">
            <div className="flex flex-wrap gap-2">
              <Button
                onClick={() => void handleRestoreBuiltIns()}
                variant="secondary"
                size="md"
              >
                <span className="flex items-center gap-1">
                  <RotateCcw className="h-4 w-4" />
                  {t("settings.postProcessing.scene.restoreBuiltIn")}
                </span>
              </Button>
            </div>
            {renderScenes(builtInScenes)}
          </div>
        </SettingContainer>
      </SettingsGroup>
    </>
  );
};
