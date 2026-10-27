"""Writes Resources/<lang>.lproj/Localizable.strings for the main UI strings."""
import pathlib

LANGS = ["es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans", "ko"]
T = {
    "Nothing playing": ["Nada en reproducción", "Rien en lecture", "Keine Wiedergabe", "Niente in riproduzione", "Nada tocando", "再生していません", "未在播放", "재생 중인 항목 없음"],
    "Connect Calendar": ["Conectar calendario", "Connecter le calendrier", "Kalender verbinden", "Collega calendario", "Conectar calendário", "カレンダーを接続", "连接日历", "캘린더 연결"],
    "No more events today": ["No hay más eventos hoy", "Plus d'événements aujourd'hui", "Heute keine weiteren Termine", "Nessun altro evento oggi", "Sem mais eventos hoje", "今日の予定はもうありません", "今天没有更多日程", "오늘 남은 일정 없음"],
    "Search clipboard": ["Buscar en el portapapeles", "Rechercher dans le presse-papiers", "Zwischenablage durchsuchen", "Cerca negli appunti", "Buscar na área de transferência", "クリップボードを検索", "搜索剪贴板", "클립보드 검색"],
    "Clear": ["Borrar", "Effacer", "Leeren", "Cancella", "Limpar", "消去", "清除", "지우기"],
    "Copy something and it will show up here": ["Copia algo y aparecerá aquí", "Copiez quelque chose et il apparaîtra ici", "Kopiere etwas, dann erscheint es hier", "Copia qualcosa e apparirà qui", "Copie algo e aparecerá aqui", "コピーするとここに表示されます", "复制内容后会显示在这里", "복사하면 여기에 표시됩니다"],
    "No matches": ["Sin resultados", "Aucun résultat", "Keine Treffer", "Nessun risultato", "Nenhum resultado", "一致なし", "无匹配项", "일치 항목 없음"],
    "Drag files onto the island to keep them here": ["Arrastra archivos a la isla para guardarlos aquí", "Glissez des fichiers sur l'île pour les garder ici", "Ziehe Dateien auf die Insel, um sie hier abzulegen", "Trascina i file sull'isola per tenerli qui", "Arraste arquivos para a ilha para guardá-los aqui", "ファイルをアイランドにドラッグして保管", "将文件拖到灵动岛上以保存在这里", "파일을 아일랜드로 끌어 여기에 보관하세요"],
    "Zip All": ["Comprimir todo", "Tout compresser", "Alle zippen", "Comprimi tutto", "Compactar tudo", "すべて圧縮", "全部压缩", "모두 압축"],
    "Open": ["Abrir", "Ouvrir", "Öffnen", "Apri", "Abrir", "開く", "打开", "열기"],
    "Show in Finder": ["Mostrar en Finder", "Afficher dans le Finder", "Im Finder zeigen", "Mostra nel Finder", "Mostrar no Finder", "Finderに表示", "在访达中显示", "Finder에서 보기"],
    "Remove from Shelf": ["Quitar del estante", "Retirer de l'étagère", "Aus Ablage entfernen", "Rimuovi dallo scaffale", "Remover da prateleira", "シェルフから削除", "从架子移除", "선반에서 제거"],
    "Unzip": ["Descomprimir", "Décompresser", "Entpacken", "Decomprimi", "Descompactar", "解凍", "解压", "압축 해제"],
    "Zip": ["Comprimir", "Compresser", "Zippen", "Comprimi", "Compactar", "圧縮", "压缩", "압축"],
    "Start": ["Iniciar", "Démarrer", "Start", "Avvia", "Iniciar", "開始", "开始", "시작"],
    "Pause": ["Pausar", "Pause", "Pause", "Pausa", "Pausar", "一時停止", "暂停", "일시 정지"],
    "Reset": ["Restablecer", "Réinitialiser", "Zurücksetzen", "Reimposta", "Redefinir", "リセット", "重置", "재설정"],
    "Skip": ["Saltar", "Passer", "Überspringen", "Salta", "Pular", "スキップ", "跳过", "건너뛰기"],
    "Add Snippet": ["Añadir fragmento", "Ajouter un extrait", "Baustein hinzufügen", "Aggiungi snippet", "Adicionar trecho", "スニペットを追加", "添加片段", "스니펫 추가"],
    "Connect Reminders": ["Conectar Recordatorios", "Connecter Rappels", "Erinnerungen verbinden", "Collega Promemoria", "Conectar Lembretes", "リマインダーを接続", "连接提醒事项", "미리 알림 연결"],
    "New reminder": ["Nuevo recordatorio", "Nouveau rappel", "Neue Erinnerung", "Nuovo promemoria", "Novo lembrete", "新規リマインダー", "新提醒事项", "새로운 미리 알림"],
    "Equalizer": ["Ecualizador", "Égaliseur", "Equalizer", "Equalizzatore", "Equalizador", "イコライザ", "均衡器", "이퀄라이저"],
    "Presets": ["Preajustes", "Préréglages", "Voreinstellungen", "Preimpostazioni", "Predefinições", "プリセット", "预设", "프리셋"],
    "Open on hover": ["Abrir al pasar el cursor", "Ouvrir au survol", "Beim Darüberfahren öffnen", "Apri al passaggio", "Abrir ao passar o cursor", "ホバーで開く", "悬停时打开", "마우스를 올리면 열기"],
    "Hover delay": ["Retraso", "Délai de survol", "Verzögerung", "Ritardo", "Atraso", "ホバーの遅延", "悬停延迟", "지연 시간"],
    "Panel size": ["Tamaño del panel", "Taille du panneau", "Größe", "Dimensione pannello", "Tamanho do painel", "パネルサイズ", "面板大小", "패널 크기"],
    "Style": ["Estilo", "Style", "Stil", "Stile", "Estilo", "スタイル", "样式", "스타일"],
    "Volume HUD": ["Indicador de volumen", "Indicateur de volume", "Lautstärkeanzeige", "Indicatore volume", "Indicador de volume", "音量HUD", "音量提示", "음량 HUD"],
    "Download alerts": ["Avisos de descarga", "Alertes de téléchargement", "Download-Hinweise", "Avvisi download", "Alertas de download", "ダウンロード通知", "下载提醒", "다운로드 알림"],
    "Call island": ["Isla de llamadas", "Île d'appel", "Anruf-Insel", "Isola chiamate", "Ilha de chamadas", "通話アイランド", "通话岛", "통화 아일랜드"],
    "Focus mode alerts": ["Avisos de modo Concentración", "Alertes de mode Concentration", "Fokus-Hinweise", "Avvisi modalità Full immersion", "Alertas de Foco", "集中モードの通知", "专注模式提醒", "집중 모드 알림"],
    "Type a command…": ["Escribe un comando…", "Tapez une commande…", "Befehl eingeben…", "Digita un comando…", "Digite um comando…", "コマンドを入力…", "输入命令…", "명령 입력…"],
    "Output": ["Salida", "Sortie", "Ausgabe", "Uscita", "Saída", "出力", "输出", "출력"],
    "Mute microphone": ["Silenciar micrófono", "Couper le micro", "Mikrofon stummschalten", "Disattiva microfono", "Silenciar microfone", "マイクを消音", "麦克风静音", "마이크 음소거"],
    "Today": ["Hoy", "Aujourd'hui", "Heute", "Oggi", "Hoje", "今日", "今天", "오늘"],
    "5-hour window": ["Ventana de 5 horas", "Fenêtre de 5 heures", "5-Stunden-Fenster", "Finestra di 5 ore", "Janela de 5 horas", "5時間枠", "5 小时窗口", "5시간 창"],
}

root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
for i, lang in enumerate(LANGS):
    d = root / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    lines = [f'"{esc(k)}" = "{esc(v[i])}";' for k, v in T.items()]
    (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"{len(T)} strings x {len(LANGS)} languages")
