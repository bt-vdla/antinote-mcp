function run(name){ for (var c of global.commandRegistry) if (c.name===name) return c.execute({parameters:[], fullText:"", userSettings:{}}); }
var r1 = run("new_dated_note"); print(r1.status, r1.payload); print(JSON.stringify(decodeURIComponent(r1.payload.split("content=")[1])));
var r2 = run("date_header"); print(r2.status, JSON.stringify(r2.payload));
for (var f of ["d_month_yyyy","month_d_yyyy","yyyy-mm-dd"]) { prefs.format=f; prefs.blank_lines="2"; print(f, JSON.stringify(run("date_header").payload)); }
prefs.format="garbage"; prefs.blank_lines="x"; print("bad prefs", JSON.stringify(run("date_header").payload));
