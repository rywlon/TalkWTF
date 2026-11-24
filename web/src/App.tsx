import React, { useEffect, useState } from 'react';
import {
  ArrowUpRight,
  BookOpen,
  LayoutGrid,
  Menu,
  Mic,
  Moon,
  Settings,
  Sun,
  WifiOff,
  X,
} from 'lucide-react';
import { AgentsView } from './components/AgentsView';
import { DashboardView } from './components/DashboardView';
import { DictationModal } from './components/DictationModal';
import { LibraryView } from './components/LibraryView';
import { OverlayPanel } from './components/OverlayPanel';
import { SettingsView } from './components/SettingsView';
import { KeycapCombo } from './components/ui/Controls';
import { AppStoreProvider, useAppStore } from './store/AppStore';
import type { AppSection, LibraryTab, SettingsPane } from './types';

const SETTINGS_PANES: SettingsPane[] = [
  'general',
  'personalization',
  'models',
  'audio',
  'advanced',
  'debug',
  'about',
];

function formatEventCombo(e: KeyboardEvent): string {
  const parts: string[] = [];
  if (e.metaKey) parts.push('Cmd');
  if (e.ctrlKey) parts.push('Ctrl');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');
  const key = e.key === ' ' ? 'Space' : e.key.length === 1 ? e.key.toUpperCase() : e.key;
  parts.push(key);
  return parts.join('+');
}

const TalkWtfMark: React.FC = () => (
  <svg
    width="20"
    height="20"
    viewBox="0 0 24 24"
    fill="none"
    aria-hidden="true"
    className="shrink-0"
  >
    <rect x="2.5" y="9.5" width="2.4" height="5" fill="currentColor" opacity="0.4" />
    <rect x="6.9" y="5.5" width="2.4" height="13" fill="currentColor" opacity="0.8" />
    <rect x="11.3" y="2.5" width="2.4" height="19" fill="var(--accent)" />
    <rect x="15.7" y="6.5" width="2.4" height="11" fill="currentColor" opacity="0.8" />
    <rect x="20.1" y="9.5" width="2.4" height="5" fill="currentColor" opacity="0.4" />
  </svg>
);

const Shell: React.FC = () => {
  const {
    settings,
    updateSettings,
    agents,
    recoveryVault,
    isOnline,
    dictationSession,
    openDictation,
    closeDictation,
    t,
  } = useAppStore();

  const [section, setSection] = useState<AppSection>('dashboard');
  const [libraryTab, setLibraryTab] = useState<LibraryTab>('history');
  const [pane, setPane] = useState<SettingsPane>('general');
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  const pendingRecoveryCount = recoveryVault.filter((r) => r.status !== 'recording_draft').length;

  // Global keyboard shortcut listener for Dictation, Auto-Route Agent, Translate, and paired Agents
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === 'INPUT' ||
          target.tagName === 'TEXTAREA' ||
          target.tagName === 'SELECT' ||
          target.isContentEditable)
      ) {
        return;
      }

      if (e.key === 'Escape' && dictationSession.open) {
        closeDictation();
        return;
      }

      const combo = formatEventCombo(e);
      const transcribeKey = settings.bindings.transcribe?.current_binding;
      const transcribeAltKey = settings.bindings.transcribe_with_post_process?.current_binding;
      const autoAgentKey = settings.bindings.agent_auto_route?.current_binding;
      const translateKey = settings.bindings.translate?.current_binding;

      if (combo && (combo === transcribeKey || combo === transcribeAltKey)) {
        e.preventDefault();
        openDictation('dictation');
        return;
      }
      if (combo && autoAgentKey && combo === autoAgentKey) {
        e.preventDefault();
        openDictation('agent_auto');
        return;
      }
      if (combo && combo === translateKey) {
        e.preventDefault();
        openDictation('translate');
        return;
      }
      for (const agent of agents) {
        const agentKey = settings.bindings[agent.bindingID]?.current_binding;
        if (combo && agentKey && combo === agentKey) {
          e.preventDefault();
          openDictation('agent', agent);
          return;
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [agents, closeDictation, dictationSession.open, openDictation, settings.bindings]);

  const isDarkEffective =
    settings.theme === 'dark' ||
    (settings.theme === 'system' &&
      typeof window !== 'undefined' &&
      window.matchMedia('(prefers-color-scheme: dark)').matches);

  const toggleTheme = () => {
    updateSettings({ theme: isDarkEffective ? 'light' : 'dark' });
  };

  const toggleLanguage = () => {
    updateSettings({ app_language: settings.app_language === 'zh' ? 'en' : 'zh' });
  };

  const openRecoveryVault = () => {
    setLibraryTab('recovery');
    setSection('library');
    setMobileMenuOpen(false);
  };

  const navItems: Array<{
    id: AppSection;
    label: string;
    icon: React.ReactNode;
    counter?: number;
  }> = [
    {
      id: 'dashboard',
      label: t('sidebar.dashboard'),
      icon: <LayoutGrid className="w-4 h-4 shrink-0" />,
    },
    {
      id: 'agents',
      label: t('sidebar.agents'),
      icon: <ArrowUpRight className="w-4 h-4 shrink-0" />,
    },
    {
      id: 'library',
      label: t('sidebar.library'),
      icon: <BookOpen className="w-4 h-4 shrink-0" />,
      counter: pendingRecoveryCount > 0 ? pendingRecoveryCount : undefined,
    },
    {
      id: 'settings',
      label: t('sidebar.settings'),
      icon: <Settings className="w-4 h-4 shrink-0" />,
    },
  ];

  const openSettingsPane = (targetPane: SettingsPane) => {
    setPane(targetPane);
    setSection('settings');
  };

  const dictationShortcut = settings.bindings.transcribe?.current_binding || 'Alt+Space';
  const autoAgentShortcut = settings.bindings.agent_auto_route?.current_binding || 'Alt+A';

  const currentBreadcrumb =
    section === 'settings'
      ? `${t('sidebar.settings')} / ${t(`settings.panes.${pane}`)}`
      : section === 'library' && libraryTab === 'recovery'
        ? `${t('sidebar.library')} / ${t('sidebar.recovery')}`
        : navItems.find((n) => n.id === section)?.label ?? 'TalkWTF';

  const sidebarContent = (
    <div className="h-full flex flex-col">
      {/* Brand Wordmark */}
      <div
        className="px-6 h-14 border-b flex items-center justify-between shrink-0"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <button
          type="button"
          onClick={() => {
            setSection('dashboard');
            setMobileMenuOpen(false);
          }}
          className="flex items-center gap-2.5 text-left cursor-pointer"
        >
          <TalkWtfMark />
          <span className="font-display text-[18px] font-bold tracking-[-0.03em] whitespace-nowrap">
            TalkWTF
          </span>
        </button>
        <button
          type="button"
          onClick={() => setMobileMenuOpen(false)}
          className="md:hidden p-1.5"
          style={{ color: 'var(--ink-secondary)' }}
          aria-label="Close navigation"
        >
          <X className="w-4 h-4" />
        </button>
      </div>

      {/* Primary Studio Capture Triggers */}
      <div
        className="px-5 py-4 border-b space-y-2"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <button
          type="button"
          onClick={() => {
            setMobileMenuOpen(false);
            openDictation('dictation');
          }}
          className="btn-accent w-full h-10 px-3.5 text-[13px] flex items-center justify-between gap-2 cursor-pointer"
        >
          <span className="flex items-center gap-2 whitespace-nowrap">
            <Mic className="w-3.5 h-3.5 shrink-0" />
            {t('dashboard.startDictation')}
          </span>
          <span className="font-mono-tabular text-[11px] opacity-85 hidden sm:inline">
            {dictationShortcut}
          </span>
        </button>

        <button
          type="button"
          onClick={() => {
            setMobileMenuOpen(false);
            openDictation('agent_auto');
          }}
          className="btn-ghost w-full h-9 px-3.5 text-[12.5px] flex items-center justify-between gap-2 cursor-pointer"
        >
          <span className="flex items-center gap-2 whitespace-nowrap">
            <ArrowUpRight className="w-3.5 h-3.5 shrink-0" style={{ color: 'var(--accent)' }} />
            {t('dashboard.startAutoAgent')}
          </span>
          <span
            className="font-mono-tabular text-[11px] hidden sm:inline"
            style={{ color: 'var(--ink-tertiary)' }}
          >
            {autoAgentShortcut}
          </span>
        </button>
      </div>

      {/* Architectural Full-Width Hairline Navigation */}
      <nav className="flex-1 py-3" aria-label="Main navigation">
        {navItems.map((item) => {
          const active = section === item.id;
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => {
                setSection(item.id);
                setMobileMenuOpen(false);
              }}
              className="relative w-full h-11 px-6 flex items-center justify-between gap-3 text-[14px] text-left transition-colors duration-150 cursor-pointer whitespace-nowrap hover:bg-[var(--bg-hover)]"
              style={{
                backgroundColor: active ? 'var(--bg-active)' : 'transparent',
                color: active ? 'var(--ink-primary)' : 'var(--ink-secondary)',
                fontWeight: active ? 600 : 500,
              }}
            >
              {active && (
                <span
                  className="absolute left-0 top-0 bottom-0 w-[2px]"
                  style={{ backgroundColor: 'var(--accent)' }}
                />
              )}
              <span className="flex items-center gap-3 min-w-0">
                <span style={{ color: active ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
                  {item.icon}
                </span>
                <span className="truncate">{item.label}</span>
              </span>
              {item.counter !== undefined && (
                <span
                  className="font-mono-tabular text-[11.5px] font-semibold"
                  style={{ color: 'var(--accent)' }}
                  title={t('recovery.title')}
                >
                  {item.counter}
                </span>
              )}
            </button>
          );
        })}
      </nav>

      {/* Quiet Utility Footer: Theme + Language Switch */}
      <div
        className="border-t grid grid-cols-2 divide-x shrink-0"
        style={{ borderColor: 'var(--border-hairline)' }}
      >
        <button
          type="button"
          onClick={toggleTheme}
          className="h-12 px-3 text-[12px] flex items-center justify-center gap-2 cursor-pointer transition-colors hover:bg-[var(--bg-hover)]"
          style={{ color: 'var(--ink-secondary)', borderColor: 'var(--border-hairline)' }}
          aria-label="Toggle theme"
        >
          {isDarkEffective ? <Sun className="w-3.5 h-3.5" /> : <Moon className="w-3.5 h-3.5" />}
          <span>
            {isDarkEffective
              ? settings.app_language === 'zh'
                ? '浅色'
                : 'Light'
              : settings.app_language === 'zh'
                ? '深色'
                : 'Dark'}
          </span>
        </button>

        <button
          type="button"
          onClick={toggleLanguage}
          className="h-12 px-3 text-[12px] font-mono-tabular flex items-center justify-center cursor-pointer transition-colors hover:bg-[var(--bg-hover)]"
          style={{ color: 'var(--ink-secondary)', borderColor: 'var(--border-hairline)' }}
          aria-label="Switch language"
        >
          {settings.app_language === 'zh' ? 'EN' : '中文'}
        </button>
      </div>
    </div>
  );

  return (
    <div
      className="h-screen w-screen overflow-hidden flex"
      style={{ backgroundColor: 'var(--bg-canvas)', color: 'var(--ink-primary)' }}
    >
      {/* Desktop Sidebar Rail */}
      <aside
        className="hidden md:block w-[240px] shrink-0 h-full border-r select-none"
        style={{
          backgroundColor: 'var(--bg-sidebar)',
          borderColor: 'var(--border-hairline)',
        }}
      >
        {sidebarContent}
      </aside>

      {/* Mobile Drawer */}
      {mobileMenuOpen && (
        <div className="fixed inset-0 z-40 md:hidden flex">
          <div
            className="w-[252px] h-full border-r shadow-2xl"
            style={{
              backgroundColor: 'var(--bg-sidebar)',
              borderColor: 'var(--border-hairline)',
            }}
          >
            {sidebarContent}
          </div>
          <div
            className="flex-1 bg-black/45"
            onClick={() => setMobileMenuOpen(false)}
            aria-hidden="true"
          />
        </div>
      )}

      {/* Main Workspace Viewport */}
      <div className="flex-1 h-full min-w-0 flex flex-col overflow-hidden">
        {/* Top Workspace Header */}
        <header
          className="h-14 shrink-0 px-6 lg:px-10 border-b flex items-center justify-between gap-6"
          style={{
            backgroundColor: 'var(--bg-canvas)',
            borderColor: 'var(--border-hairline)',
          }}
        >
          <div className="flex items-center gap-3 min-w-0">
            <button
              type="button"
              onClick={() => setMobileMenuOpen(true)}
              className="md:hidden p-2 -ml-2 cursor-pointer"
              style={{ color: 'var(--ink-secondary)' }}
              aria-label="Open navigation"
            >
              <Menu className="w-4 h-4" />
            </button>
            <div className="flex items-center gap-2 text-[13px] truncate">
              <span style={{ color: 'var(--ink-tertiary)' }} className="hidden sm:inline">
                TalkWTF
              </span>
              <span style={{ color: 'var(--ink-tertiary)' }} className="hidden sm:inline">
                /
              </span>
              <span className="font-medium truncate">{currentBreadcrumb}</span>
            </div>
          </div>

          <div className="flex items-center gap-4 shrink-0">
            {!isOnline && (
              <div
                className="flex items-center gap-1.5 text-[12px] font-mono-tabular"
                style={{ color: 'var(--status-warn)' }}
              >
                <WifiOff className="w-3.5 h-3.5 shrink-0" />
                <span>
                  {settings.app_language === 'zh'
                    ? '离线 · 录音自动落盘保护'
                    : 'OFFLINE · VAULT PROTECTION ON'}
                </span>
              </div>
            )}

            <div
              className="hidden lg:flex items-center gap-2 text-[12px]"
              style={{ color: 'var(--ink-secondary)' }}
            >
              <span>{settings.app_language === 'zh' ? '智能路由' : 'Auto-Route'}</span>
              <KeycapCombo combo={autoAgentShortcut} muted />
            </div>

            {section !== 'dashboard' && (
              <button
                type="button"
                onClick={() => openDictation('dictation')}
                className="btn-accent h-8 px-3.5 text-[12.5px] flex items-center gap-1.5 cursor-pointer"
              >
                <Mic className="w-3.5 h-3.5" />
                {t('dashboard.startDictation')}
              </button>
            )}
          </div>
        </header>

        {/* Active Viewport Content */}
        <main className="flex-1 min-h-0 overflow-hidden flex flex-col">
          {section === 'dashboard' && (
            <DashboardView
              onOpenAgents={() => setSection('agents')}
              onOpenLibrary={() => {
                setLibraryTab('history');
                setSection('library');
              }}
              onOpenRecoveryVault={openRecoveryVault}
              onOpenSettingsPane={openSettingsPane}
            />
          )}

          {section === 'agents' && <AgentsView />}

          {section === 'library' && (
            <LibraryView activeTab={libraryTab} onTabChange={setLibraryTab} />
          )}

          {section === 'settings' && (
            <div className="h-full flex flex-col overflow-hidden">
              {/* Crisp Underline Navigation Strip for Settings Panes */}
              <div
                className="shrink-0 border-b px-6 lg:px-10 overflow-x-auto"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <div className="max-w-[1080px] mx-auto flex items-center gap-6">
                  {SETTINGS_PANES.map((item) => {
                    const active = pane === item;
                    return (
                      <button
                        key={item}
                        type="button"
                        onClick={() => setPane(item)}
                        className="relative py-3.5 text-[13.5px] font-medium whitespace-nowrap shrink-0 transition-colors cursor-pointer"
                        style={{
                          color: active ? 'var(--ink-primary)' : 'var(--ink-secondary)',
                        }}
                      >
                        {t(`settings.panes.${item}`)}
                        {active && (
                          <span
                            className="absolute left-0 right-0 bottom-0 h-[2px]"
                            style={{ backgroundColor: 'var(--accent)' }}
                          />
                        )}
                      </button>
                    );
                  })}
                </div>
              </div>
              <SettingsView pane={pane} />
            </div>
          )}
        </main>
      </div>

      <DictationModal onOpenRecoveryVault={openRecoveryVault} />
      <OverlayPanel
        onDiscardRecording={closeDictation}
        onOpenRecoveryVault={openRecoveryVault}
      />
    </div>
  );
};

export function App() {
  return (
    <AppStoreProvider>
      <Shell />
    </AppStoreProvider>
  );
}

export default App;
