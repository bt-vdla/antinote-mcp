// ===============================
// Antinote Extension: date_note
// Version 1.0.0
// Opens a NEW note with today's date in bold at the top.
// ===============================

(function () {
  const extensionName = "date_note";

  const extensionRoot = new Extension({
    name: extensionName,
    version: "1.0.0",
    endpoints: [],
    requiredAPIKeys: [],
    author: "bharat",
    category: "Date & Time",
    dataScope: "none" // never reads note content
  });

  // --- preferences ---
  const formatPref = new Preference({
    key: "format",
    label: "Date Format",
    type: "selectOne",
    defaultValue: "weekday_d_mon_yyyy",
    options: ["weekday_d_mon_yyyy", "d_month_yyyy", "month_d_yyyy", "yyyy-mm-dd"],
    helpText: "weekday_d_mon_yyyy = Thursday, 5 Nov 2026 · d_month_yyyy = 5 November 2026 · month_d_yyyy = November 5, 2026 · yyyy-mm-dd = 2026-11-05"
  });
  extensionRoot.register_preference(formatPref);

  const blankLinesPref = new Preference({
    key: "blank_lines",
    label: "Blank lines after date",
    type: "selectOne",
    defaultValue: "1",
    options: ["0", "1", "2"],
    helpText: "How many empty lines to leave under the date."
  });
  extensionRoot.register_preference(blankLinesPref);

  // --- helpers ---
  const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const MONTHS = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"];
  const pad2 = (n) => String(n).padStart(2, "0");

  const formatDate = (d, format) => {
    const day = d.getDate();
    const month = MONTHS[d.getMonth()];
    const year = d.getFullYear();
    switch (format) {
      case "d_month_yyyy": return `${day} ${month} ${year}`;
      case "month_d_yyyy": return `${month} ${day}, ${year}`;
      case "yyyy-mm-dd": return `${year}-${pad2(d.getMonth() + 1)}-${pad2(day)}`;
      case "weekday_d_mon_yyyy":
      default: return `${DAYS[d.getDay()]}, ${day} ${month.slice(0, 3)} ${year}`;
    }
  };

  const readPref = (key, fallback) => {
    try {
      const v = getExtensionPreference(extensionName, key);
      return (v === undefined || v === null || v === "") ? fallback : String(v);
    } catch (e) {
      return fallback;
    }
  };

  const buildHeader = () => {
    const format = readPref("format", "weekday_d_mon_yyyy");
    const blank = Math.max(0, Math.min(2, parseInt(readPref("blank_lines", "1"), 10) || 0));
    return `**${formatDate(new Date(), format)}**` + "\n".repeat(blank + 1);
  };

  // --- command 1: open a brand-new note with the bold date ---
  const new_dated_note = new Command({
    name: "new_dated_note",
    parameters: [],
    type: "openURL",
    helpText: "Open a new note with today's date in bold at the top.",
    tutorials: [
      new TutorialCommand({ command: "new_dated_note", description: "New note starting with **Thursday, 5 Nov 2026**" })
    ],
    extension: extensionRoot
  });

  new_dated_note.execute = function (payload) {
    const url = "antinote://x-callback-url/createNote?content=" + encodeURIComponent(buildHeader());
    return new ReturnObject({ status: "success", message: "Opening a new dated note.", payload: url });
  };

  // --- command 2 (fallback): turn the current line into the bold date ---
  // Use in an empty note (⌘N) if the URL route above is ever blocked.
  const date_header = new Command({
    name: "date_header",
    parameters: [],
    type: "replaceLine",
    helpText: "Replace this line with today's date in bold (use at the top of a new, empty note).",
    tutorials: [
      new TutorialCommand({ command: "date_header", description: "Replace this line with **Thursday, 5 Nov 2026**" })
    ],
    extension: extensionRoot
  });

  date_header.execute = function (payload) {
    return new ReturnObject({ status: "success", message: "Date inserted.", payload: buildHeader() });
  };
})();
