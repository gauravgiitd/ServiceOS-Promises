const DATA_URL = "data/promise_instances.json";
const META_URL = "data/metadata.json";

const VALID_BUCKETS = new Set([
  "MET_EARLY",
  "MET",
  "MET_WITH_DELAY",
  "NOT_MET_REACHED_TOO_EARLY",
  "NOT_MET_CANCELLED_AFTER_CUTOFF",
  "NOT_MET_RESCHEDULED_AFTER_CUTOFF",
  "NOT_MET_REACHED_TOO_LATE",
  "NOT_MET_REST_REASONS",
]);

const SUCCESS_BUCKETS = new Set(["MET_EARLY", "MET", "MET_WITH_DELAY"]);
const FAILURE_BUCKETS = new Set([
  "NOT_MET_REACHED_TOO_EARLY",
  "NOT_MET_CANCELLED_AFTER_CUTOFF",
  "NOT_MET_RESCHEDULED_AFTER_CUTOFF",
  "NOT_MET_REACHED_TOO_LATE",
  "NOT_MET_REST_REASONS",
]);
const SINGLE_DATE_PRESETS = new Set(["yesterday", "dayBefore"]);
const RANGE_DATE_PRESETS = new Set(["last7", "last14"]);
const DATE_PRESETS = new Set([...SINGLE_DATE_PRESETS, ...RANGE_DATE_PRESETS]);

const state = {
  records: [],
  metadata: null,
  dateFilter: {
    mode: "single",
    preset: "yesterday",
    singleDate: null,
    startDate: null,
    endDate: null,
  },
  selectedCity: null,
  selectedAgentId: null,
  agentSearch: "",
  sort: { key: "valid_promises", direction: "desc" },
  view: "cities",
  showExcluded: false,
};

const els = {
  dataMeta: document.getElementById("dataMeta"),
  dateFilterRoot: document.getElementById("dateFilterRoot"),
  cityView: document.getElementById("cityView"),
  agentView: document.getElementById("agentView"),
  timelineView: document.getElementById("timelineView"),
  tooltip: document.getElementById("tooltip"),
};

init();

async function init() {
  try {
    const [records, metadata] = await Promise.all([
      fetch(DATA_URL).then((r) => r.json()),
      fetch(META_URL).then((r) => r.json()),
    ]);
    state.records = records;
    state.metadata = metadata;
    applyDatePreset("yesterday", { rerender: false });
    applyRouteFromUrl({ replaceMissing: true });
    renderMeta();
    render();
  } catch (error) {
    els.cityView.innerHTML = `<div class="empty-state">Could not load generated promise data. Run <code>python3 scripts/refresh_data.py</code> and refresh this page.</div>`;
    els.dataMeta.textContent = "Data not available";
    console.error(error);
  }
}

function renderMeta() {
  const meta = state.metadata || {};
  const range = meta.date_range ? `${meta.date_range.start_date} to ${meta.date_range.end_date}` : "no date range";
  const generated = meta.generated_at ? `generated ${meta.generated_at}` : "not generated yet";
  els.dataMeta.textContent = `${formatInt(meta.record_count || state.records.length)} promise instances, ${range}, ${generated}`;
}

function render() {
  renderDateFilter();
  els.cityView.hidden = state.view !== "cities";
  els.agentView.hidden = state.view !== "agents";
  els.timelineView.hidden = state.view !== "timeline";

  if (state.view === "cities") renderCities();
  if (state.view === "agents") renderAgents();
  if (state.view === "timeline") renderTimelineView();
}

function renderDateFilter() {
  const range = activeDateRange();
  const isDay = state.dateFilter.mode === "single";
  els.dateFilterRoot.innerHTML = `
    <div class="date-filter-main">
      <div>
        <div class="date-filter-eyebrow">Viewing</div>
        <div class="date-filter-value">${escapeHtml(dateRangeLabel(range))}</div>
      </div>
      <div class="date-mode-toggle" role="group" aria-label="Date filter mode">
        <button class="${isDay ? "active" : ""}" data-date-mode="single">Day</button>
        <button class="${!isDay ? "active" : ""}" data-date-mode="range">Range</button>
      </div>
    </div>
    <div class="date-filter-row">
      ${isDay ? singleDayControls() : rangeControls()}
    </div>
  `;

  els.dateFilterRoot.querySelectorAll("[data-date-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      setDateMode(button.dataset.dateMode);
      resetDrilldownIfEmpty();
      navigateToCurrentRoute();
    });
  });

  els.dateFilterRoot.querySelectorAll("[data-date-preset]").forEach((button) => {
    button.addEventListener("click", () => applyDatePreset(button.dataset.datePreset));
  });

  const singleInput = els.dateFilterRoot.querySelector("#singleDateInput");
  if (singleInput) {
    singleInput.addEventListener("change", (event) => {
      state.dateFilter.mode = "single";
      state.dateFilter.preset = "custom";
      state.dateFilter.singleDate = clampDate(event.target.value);
      resetDrilldownIfEmpty();
      navigateToCurrentRoute();
    });
  }

  const startInput = els.dateFilterRoot.querySelector("#rangeStartInput");
  const endInput = els.dateFilterRoot.querySelector("#rangeEndInput");
  if (startInput && endInput) {
    const updateRange = () => {
      state.dateFilter.mode = "range";
      state.dateFilter.preset = "custom";
      const start = clampDate(startInput.value);
      const end = clampDate(endInput.value);
      if (start <= end) {
        state.dateFilter.startDate = start;
        state.dateFilter.endDate = end;
      } else {
        state.dateFilter.startDate = end;
        state.dateFilter.endDate = start;
      }
      resetDrilldownIfEmpty();
      navigateToCurrentRoute();
    };
    startInput.addEventListener("change", updateRange);
    endInput.addEventListener("change", updateRange);
  }
}

function singleDayControls() {
  const { min, max } = dataDateBounds();
  const value = activeDateRange().start;
  return `
    <div class="date-preset-group">
      ${datePresetButton("yesterday", "Yesterday")}
      ${datePresetButton("dayBefore", "Day before")}
    </div>
    <input id="singleDateInput" class="date-input" type="date" min="${min}" max="${max}" value="${value}" />
  `;
}

function rangeControls() {
  const { min, max } = dataDateBounds();
  const range = activeDateRange();
  return `
    <div class="date-preset-group">
      ${datePresetButton("last7", "Last 7 days")}
      ${datePresetButton("last14", "Last 14 days")}
    </div>
    <div class="date-range-inputs">
      <input id="rangeStartInput" class="date-input" type="date" min="${min}" max="${max}" value="${range.start}" />
      <span>to</span>
      <input id="rangeEndInput" class="date-input" type="date" min="${min}" max="${max}" value="${range.end}" />
    </div>
  `;
}

function datePresetButton(preset, label) {
  const active = state.dateFilter.preset === preset ? " active" : "";
  return `<button class="preset-chip${active}" data-date-preset="${preset}">${escapeHtml(label)}</button>`;
}

function setDateMode(mode) {
  const currentRange = activeDateRange();

  if (mode === "single") {
    state.dateFilter.mode = "single";
    state.dateFilter.singleDate = clampDate(state.dateFilter.singleDate || currentRange.end);
    state.dateFilter.preset = singlePresetForDate(state.dateFilter.singleDate);
    return;
  }

  if (mode === "range") {
    state.dateFilter.mode = "range";
    if (!state.dateFilter.startDate || !state.dateFilter.endDate) {
      applyDatePreset("last7", { rerender: false });
      return;
    }
    state.dateFilter.startDate = clampDate(state.dateFilter.startDate);
    state.dateFilter.endDate = clampDate(state.dateFilter.endDate);
    state.dateFilter.preset = rangePresetForDates(state.dateFilter.startDate, state.dateFilter.endDate);
  }
}

function applyDatePreset(preset, options = {}) {
  const { rerender = true } = options;
  const { min, max } = dataDateBounds();
  state.dateFilter.preset = preset;

  if (preset === "yesterday") {
    state.dateFilter.mode = "single";
    state.dateFilter.singleDate = clampDate(addDays(max, -1));
  } else if (preset === "dayBefore") {
    state.dateFilter.mode = "single";
    state.dateFilter.singleDate = clampDate(addDays(max, -2));
  } else if (preset === "last7") {
    state.dateFilter.mode = "range";
    state.dateFilter.startDate = clampDate(addDays(max, -6));
    state.dateFilter.endDate = max;
  } else if (preset === "last14") {
    state.dateFilter.mode = "range";
    state.dateFilter.startDate = clampDate(addDays(max, -13));
    state.dateFilter.endDate = max;
  }

  if (state.dateFilter.startDate && state.dateFilter.startDate < min) state.dateFilter.startDate = min;
  if (state.dateFilter.endDate && state.dateFilter.endDate > max) state.dateFilter.endDate = max;
  resetDrilldownIfEmpty();
  if (rerender) navigateToCurrentRoute();
}

function activeDateRange() {
  const { max } = dataDateBounds();
  if (state.dateFilter.mode === "single") {
    const date = clampDate(state.dateFilter.singleDate || addDays(max, -1));
    return { start: date, end: date };
  }

  const start = clampDate(state.dateFilter.startDate || addDays(max, -13));
  const end = clampDate(state.dateFilter.endDate || max);
  return start <= end ? { start, end } : { start: end, end: start };
}

function filteredRecords() {
  const { start, end } = activeDateRange();
  return state.records.filter((record) => record.promise_date >= start && record.promise_date <= end);
}

function dataDateBounds() {
  const metaRange = state.metadata?.date_range;
  if (metaRange?.start_date && metaRange?.end_date) {
    return { min: metaRange.start_date, max: metaRange.end_date };
  }

  const dates = state.records.map((record) => record.promise_date).filter(Boolean).sort();
  const fallback = isoToday();
  return {
    min: dates[0] || fallback,
    max: dates.at(-1) || fallback,
  };
}

function resetDrilldownIfEmpty() {
  if (!state.selectedCity) return;
  const visible = filteredRecords();
  const cityHasRecords = visible.some((record) => (record.city_name || "Unknown") === state.selectedCity);
  if (!cityHasRecords) {
    state.view = "cities";
    state.selectedCity = null;
    state.selectedAgentId = null;
    return;
  }

  if (!state.selectedAgentId || state.view !== "timeline") return;
  const agentHasRecords = visible.some((record) => {
    return (
      (record.city_name || "Unknown") === state.selectedCity &&
      String(record.agent_id || "unknown") === String(state.selectedAgentId)
    );
  });
  if (!agentHasRecords) {
    state.view = "agents";
    state.selectedAgentId = null;
  }
}

function dateRangeLabel(range) {
  if (range.start === range.end) return friendlyDate(range.start);
  return `${friendlyDate(range.start)} to ${friendlyDate(range.end)}`;
}

function friendlyDate(dateString) {
  const { max } = dataDateBounds();
  if (dateString === max) return `Today (${dateString})`;
  if (dateString === addDays(max, -1)) return `Yesterday (${dateString})`;
  if (dateString === addDays(max, -2)) return `Day before yesterday (${dateString})`;
  return dateString;
}

function clampDate(dateString) {
  const { min, max } = dataDateBounds();
  if (!dateString) return max;
  if (dateString < min) return min;
  if (dateString > max) return max;
  return dateString;
}

function addDays(dateString, days) {
  const next = new Date(dateToUtcMs(dateString) + days * 24 * 60 * 60 * 1000);
  return next.toISOString().slice(0, 10);
}

function dateToUtcMs(dateString) {
  const [year, month, day] = dateString.split("-").map(Number);
  return Date.UTC(year, month - 1, day);
}

function isoToday() {
  return new Date().toISOString().slice(0, 10);
}

function applyRouteFromUrl(options = {}) {
  const route = parseRoute();
  applyDateParams(route.params);

  state.view = route.view;
  state.selectedCity = route.city;
  state.selectedAgentId = route.agentId;
  state.showExcluded = route.showExcluded;
  resetDrilldownIfEmpty();

  if (window.location.hash !== buildRouteHash()) {
    history.replaceState(null, "", buildRouteHash());
  }
}

function parseRoute() {
  const hash = window.location.hash.replace(/^#/, "");
  const [rawPath = "", rawQuery = ""] = hash.split("?");
  const path = rawPath || "/global";
  const params = new URLSearchParams(rawQuery);
  const city = params.get("city") || null;
  const agentId = params.get("agent_id") || null;

  if (path === "/agent" && city && agentId) {
    return { view: "timeline", city, agentId, params, showExcluded: params.get("show_excluded") === "1" };
  }

  if (path === "/city" && city) {
    return { view: "agents", city, agentId: null, params, showExcluded: false };
  }

  return { view: "cities", city: null, agentId: null, params, showExcluded: false };
}

function applyDateParams(params) {
  const mode = params.get("date_mode");
  const preset = params.get("date_preset");

  if (DATE_PRESETS.has(preset) && presetMatchesMode(mode, preset)) {
    applyDatePreset(preset, { rerender: false });
    return;
  }

  if (mode === "single") {
    state.dateFilter.mode = "single";
    state.dateFilter.preset = "custom";
    state.dateFilter.singleDate = clampDate(params.get("date") || activeDateRange().start);
    return;
  }

  if (mode === "range") {
    state.dateFilter.mode = "range";
    state.dateFilter.preset = "custom";
    const start = clampDate(params.get("start_date") || activeDateRange().start);
    const end = clampDate(params.get("end_date") || activeDateRange().end);
    state.dateFilter.startDate = start <= end ? start : end;
    state.dateFilter.endDate = start <= end ? end : start;
  }
}

function presetMatchesMode(mode, preset) {
  if (mode === "single") return SINGLE_DATE_PRESETS.has(preset);
  if (mode === "range") return RANGE_DATE_PRESETS.has(preset);
  return DATE_PRESETS.has(preset);
}

function navigateToCurrentRoute(options = {}) {
  const hash = buildRouteHash();
  if (window.location.hash === hash) {
    render();
    return;
  }

  if (options.replace) {
    history.replaceState(null, "", hash);
    render();
  } else {
    window.location.hash = hash;
  }
}

function buildRouteHash(overrides = {}) {
  const view = overrides.view || state.view;
  const city = overrides.city ?? state.selectedCity;
  const agentId = overrides.agentId ?? state.selectedAgentId;
  const showExcluded = overrides.showExcluded ?? state.showExcluded;
  const params = routeDateParams();

  if (view === "timeline" && city && agentId) {
    params.set("city", city);
    params.set("agent_id", agentId);
    if (showExcluded) params.set("show_excluded", "1");
    return `#/agent?${params.toString()}`;
  }

  if (view === "agents" && city) {
    params.set("city", city);
    return `#/city?${params.toString()}`;
  }

  return `#/global?${params.toString()}`;
}

function routeDateParams() {
  const params = new URLSearchParams();
  const preset = presetMatchesMode(state.dateFilter.mode, state.dateFilter.preset) ? state.dateFilter.preset : "custom";
  params.set("date_mode", state.dateFilter.mode);
  params.set("date_preset", preset);

  if (state.dateFilter.mode === "single") {
    params.set("date", activeDateRange().start);
  } else {
    const range = activeDateRange();
    params.set("start_date", range.start);
    params.set("end_date", range.end);
  }

  return params;
}

function singlePresetForDate(dateString) {
  const { max } = dataDateBounds();
  if (dateString === clampDate(addDays(max, -1))) return "yesterday";
  if (dateString === clampDate(addDays(max, -2))) return "dayBefore";
  return "custom";
}

function rangePresetForDates(startDate, endDate) {
  const { max } = dataDateBounds();
  if (startDate === clampDate(addDays(max, -6)) && endDate === max) return "last7";
  if (startDate === clampDate(addDays(max, -13)) && endDate === max) return "last14";
  return "custom";
}

window.addEventListener("hashchange", () => {
  applyRouteFromUrl();
  render();
});

function renderCities() {
  const visibleRecords = filteredRecords();
  const rows = aggregateBy(visibleRecords, (r) => r.city_name || "Unknown")
    .map(([city, records]) => ({ city, ...metrics(records) }))
    .sort(sorter());

  els.cityView.innerHTML = `
    <div class="section-head">
      <div>
        ${breadcrumbs([{ label: "Cities", current: true }])}
        <h2>Cities</h2>
        <p>Click a city to inspect agent-level promise performance.</p>
      </div>
    </div>
    ${metricGrid(metrics(visibleRecords), state.records)}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            ${th("city", "City")}
            ${th("total_tasks", "Tasks")}
            ${th("valid_promises", "Valid promises")}
            ${th("success_pct", "Success %")}
            ${th("failure_pct", "Failure %")}
            ${th("not_met_and_no_blockers_count", "No-blocker misses")}
            ${th("late_reschedule_count", "Late reschedules")}
            ${th("late_cancel_count", "Late cancels")}
            ${th("excluded_count", "Excluded")}
          </tr>
        </thead>
        <tbody>
          ${rows.map(cityRow).join("")}
        </tbody>
      </table>
    </div>
  `;

  bindSortHeaders(els.cityView);
  els.cityView.querySelectorAll("tbody tr").forEach((row) => {
    row.addEventListener("click", () => {
      state.selectedCity = row.dataset.city;
      state.sort = { key: "valid_promises", direction: "desc" };
      state.view = "agents";
      navigateToCurrentRoute();
    });
  });
}

function renderAgents() {
  const cityRecords = filteredRecords().filter((r) => (r.city_name || "Unknown") === state.selectedCity);
  const rows = aggregateBy(cityRecords, (r) => `${r.agent_id || "unknown"}|${r.agent_name || "Unknown agent"}`)
    .map(([key, records]) => {
      const [agent_id, agent_name] = key.split("|");
      return { agent_id, agent_name, ...metrics(records) };
    })
    .filter((r) => r.agent_name.toLowerCase().includes(state.agentSearch.toLowerCase()))
    .sort(sorter());

  els.agentView.innerHTML = `
    <div class="section-head">
      <div>
        ${breadcrumbs([
          { label: "Cities", href: buildRouteHash({ view: "cities" }) },
          { label: state.selectedCity, current: true },
        ])}
        <h2>${escapeHtml(state.selectedCity)}</h2>
        <p>Agent-level promise metrics. Click an agent to open the timeline.</p>
      </div>
      <div class="toolbar">
        <input id="agentSearch" type="search" placeholder="Search agent" value="${escapeHtml(state.agentSearch)}" />
      </div>
    </div>
    ${metricGrid(
      metrics(cityRecords),
      state.records.filter((r) => (r.city_name || "Unknown") === state.selectedCity),
    )}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            ${th("agent_name", "Agent")}
            ${th("total_tasks", "Tasks")}
            ${th("valid_promises", "Valid promises")}
            ${th("success_pct", "Success %")}
            ${th("failure_pct", "Failure %")}
            ${th("not_met_and_no_blockers_count", "No-blocker misses")}
            ${th("late_reschedule_count", "Late reschedules")}
            ${th("late_cancel_count", "Late cancels")}
            ${th("excluded_count", "Excluded")}
          </tr>
        </thead>
        <tbody>
          ${rows.map(agentRow).join("")}
        </tbody>
      </table>
    </div>
  `;

  bindSortHeaders(els.agentView);
  els.agentView.querySelector("#agentSearch").addEventListener("input", (event) => {
    state.agentSearch = event.target.value;
    renderAgents();
  });
  els.agentView.querySelectorAll("tbody tr").forEach((row) => {
    row.addEventListener("click", () => {
      state.selectedAgentId = row.dataset.agentId;
      state.view = "timeline";
      navigateToCurrentRoute();
    });
  });
}

function renderTimelineView() {
  const agentRecordsAll = filteredRecords()
    .filter((r) => (r.city_name || "Unknown") === state.selectedCity)
    .filter((r) => String(r.agent_id || "unknown") === String(state.selectedAgentId));
  const agentName = agentRecordsAll[0]?.agent_name || "Unknown agent";
  const shownRecords = agentRecordsAll
    .filter((r) => state.showExcluded || r.promise_bucket !== "EXCLUDED")
    .sort((a, b) => compareTs(a.slot_start_at_ist, b.slot_start_at_ist) || compareTs(a.scheduled_start_at_ist, b.scheduled_start_at_ist));

  els.timelineView.innerHTML = `
    <div class="section-head">
      <div>
        ${breadcrumbs([
          { label: "Cities", href: buildRouteHash({ view: "cities" }) },
          { label: state.selectedCity, href: buildRouteHash({ view: "agents", city: state.selectedCity, agentId: null, showExcluded: false }) },
          { label: agentName, current: true },
        ])}
        <h2>${escapeHtml(agentName)}</h2>
        <p>${escapeHtml(state.selectedCity)} promise timeline</p>
      </div>
      <div class="toolbar">
        <label class="checkbox">
          <input id="showExcluded" type="checkbox" ${state.showExcluded ? "checked" : ""} />
          Show excluded
        </label>
      </div>
    </div>
    ${metricGrid(
      metrics(agentRecordsAll),
      state.records
        .filter((r) => (r.city_name || "Unknown") === state.selectedCity)
        .filter((r) => String(r.agent_id || "unknown") === String(state.selectedAgentId)),
    )}
    <div class="legend">
      <span class="legend-item"><span class="legend-swatch" style="background: var(--green)"></span>Met</span>
      <span class="legend-item"><span class="legend-swatch" style="background: var(--red)"></span>Not met, no blocker</span>
      <span class="legend-item"><span class="legend-swatch" style="background: var(--orange)"></span>Not met, blocked</span>
      <span class="legend-item">▼ scheduled</span>
      <span class="legend-item">● start trip</span>
      <span class="legend-item">◆ reached</span>
      <span class="legend-item">■ completed</span>
      <span class="legend-item">✕ reschedule/cancel</span>
    </div>
    ${shownRecords.length ? timeline(shownRecords) : `<div class="empty-state">No promise rows to show for this filter.</div>`}
  `;

  els.timelineView.querySelector("#showExcluded").addEventListener("change", (event) => {
    state.showExcluded = event.target.checked;
    navigateToCurrentRoute();
  });
}

function breadcrumbs(items) {
  return `
    <nav class="breadcrumbs" aria-label="Breadcrumb">
      <ol>
        ${items.map(breadcrumbItem).join("")}
      </ol>
    </nav>
  `;
}

function breadcrumbItem(item) {
  const label = escapeHtml(item.label || "");
  if (item.current) {
    return `<li><span class="breadcrumb-current" aria-current="page">${label}</span></li>`;
  }
  return `<li><a class="breadcrumb-link" href="${escapeAttr(item.href)}">${label}</a></li>`;
}

function metricGrid(m, trendRecords) {
  const trends = metricTrends(trendRecords);
  return `
    <div class="metric-grid">
      ${metricCard("Success", `${formatPct(m.success_pct)}%`, `${formatInt(m.success_count)} successful`, trends.success_pct)}
      ${metricCard("Valid Promises", formatInt(m.valid_promises), `${formatInt(m.total_promises)} total promises`, trends.valid_promises)}
      ${metricCard("No-Blocker Misses", formatInt(m.not_met_and_no_blockers_count), `${formatPct(m.no_blocker_pct)}% of valid`, trends.not_met_and_no_blockers_count)}
      ${metricCard("Late Reschedules", formatInt(m.late_reschedule_count), `${formatPct(m.late_reschedule_pct)}% of valid`, trends.late_reschedule_count)}
      ${metricCard("Late Cancels", formatInt(m.late_cancel_count), `${formatPct(m.late_cancel_pct)}% of valid`, trends.late_cancel_count)}
      ${metricCard("Tasks", formatInt(m.total_tasks), `${formatInt(m.excluded_count)} excluded promises`, trends.total_tasks)}
    </div>
  `;
}

function metricCard(label, value, sub, trend) {
  return `
    <div class="metric" tabindex="0">
      <div class="label">${escapeHtml(label)}</div>
      <div class="value">${escapeHtml(value)}</div>
      <div class="sub">${escapeHtml(sub)}</div>
      ${trendPopover(label, trend)}
    </div>
  `;
}

function metricTrends(records) {
  const days = trendDays();
  const recordsByDate = new Map(days.map((day) => [day, []]));
  records.forEach((record) => {
    if (!recordsByDate.has(record.promise_date)) return;
    recordsByDate.get(record.promise_date).push(record);
  });

  const daily = days.map((day) => {
    const dayMetrics = metrics(recordsByDate.get(day) || []);
    return { day, metrics: dayMetrics };
  });

  return {
    success_pct: trendSeries(daily, "success_pct", { format: "pct" }),
    valid_promises: trendSeries(daily, "valid_promises"),
    not_met_and_no_blockers_count: trendSeries(daily, "not_met_and_no_blockers_count"),
    late_reschedule_count: trendSeries(daily, "late_reschedule_count"),
    late_cancel_count: trendSeries(daily, "late_cancel_count"),
    total_tasks: trendSeries(daily, "total_tasks"),
  };
}

function trendDays() {
  const active = activeDateRange();
  const start = state.dateFilter.mode === "single" ? addDays(active.end, -6) : active.start;
  const days = [];
  let current = start;
  while (current <= active.end) {
    days.push(current);
    current = addDays(current, 1);
  }
  return days;
}

function trendSeries(daily, key, options = {}) {
  const values = daily.map((entry) => Number(entry.metrics[key] || 0));
  const max = Math.max(...values, options.format === "pct" ? 100 : 1);
  const labelStep = daily.length <= 7 ? 1 : Math.ceil((daily.length - 1) / 4);
  return daily.map((entry, index) => ({
    date: entry.day,
    label: shortDate(entry.day),
    showLabel: index === 0 || index === daily.length - 1 || (index % labelStep === 0 && index <= daily.length - 1 - labelStep),
    value: values[index],
    formatted: options.format === "pct" ? `${formatPct(values[index])}%` : formatInt(values[index]),
    compact: options.format === "pct" ? `${Math.round(values[index])}%` : formatCompact(values[index]),
    height: Math.max(4, Math.round((values[index] / max) * 42)),
  }));
}

function trendPopover(label, trend) {
  return `
    <div class="metric-trend" role="presentation">
      <div class="metric-trend-head">
        <span>${escapeHtml(label)} trend</span>
        <small>${escapeHtml(trendWindowLabel())}</small>
        <button class="metric-trend-close" type="button" aria-label="Close trend" data-trend-close>&times;</button>
      </div>
      <div class="trend-bars">
        ${trend.map(trendBar).join("")}
      </div>
    </div>
  `;
}

function trendBar(point) {
  return `
    <button class="trend-bar-wrap" type="button" data-trend-date="${escapeAttr(point.date)}" data-tooltip="${escapeAttr(`${point.label}\n${point.formatted}\nClick to view this day`)}" aria-label="View ${escapeAttr(point.label)}">
      <div class="trend-bar-value">${escapeHtml(point.compact)}</div>
      <div class="trend-bar" style="height:${point.height}px"></div>
      <div class="trend-bar-label">${point.showLabel ? escapeHtml(point.label) : ""}</div>
    </button>
  `;
}

function trendWindowLabel() {
  const days = trendDays();
  if (state.dateFilter.mode === "single") return "Last 7 days";
  return days.length === 1 ? "Selected day" : `${days.length} days`;
}

function closeMetricTrend(metric, options = {}) {
  if (!metric) return;
  const { dismiss = true } = options;
  if (dismiss) metric.classList.add("trend-dismissed");
  metric.blur();
  const active = document.activeElement;
  if (active instanceof HTMLElement && metric.contains(active)) active.blur();
}

function openTrendDate(dateString) {
  state.dateFilter.mode = "single";
  state.dateFilter.singleDate = clampDate(dateString);
  state.dateFilter.preset = singlePresetForDate(state.dateFilter.singleDate);
  resetDrilldownIfEmpty();
  navigateToCurrentRoute();
}

function cityRow(row) {
  return `
    <tr data-city="${escapeAttr(row.city)}">
      <td>${escapeHtml(row.city)}</td>
      <td>${formatInt(row.total_tasks)}</td>
      <td>${formatInt(row.valid_promises)}</td>
      <td>${successBadge(row.success_pct)}</td>
      <td>${formatPct(row.failure_pct)}%</td>
      <td>${formatInt(row.not_met_and_no_blockers_count)}</td>
      <td>${formatInt(row.late_reschedule_count)}</td>
      <td>${formatInt(row.late_cancel_count)}</td>
      <td>${formatInt(row.excluded_count)}</td>
    </tr>
  `;
}

function agentRow(row) {
  return `
    <tr data-agent-id="${escapeAttr(row.agent_id)}">
      <td>${escapeHtml(row.agent_name)}</td>
      <td>${formatInt(row.total_tasks)}</td>
      <td>${formatInt(row.valid_promises)}</td>
      <td>${successBadge(row.success_pct)}</td>
      <td>${formatPct(row.failure_pct)}%</td>
      <td>${formatInt(row.not_met_and_no_blockers_count)}</td>
      <td>${formatInt(row.late_reschedule_count)}</td>
      <td>${formatInt(row.late_cancel_count)}</td>
      <td>${formatInt(row.excluded_count)}</td>
    </tr>
  `;
}

function timeline(records) {
  const minutes = [];
  records.forEach((r) => {
    ["slot_start_at_ist", "slot_end_at_ist"].forEach((key) => {
      const minute = minuteOfDay(r[key]);
      if (minute !== null) minutes.push(minute);
    });

    [
      "scheduled_start_at_ist",
      "start_trip_at_ist",
      "customer_reached_at_ist",
      "completed_at_ist",
      "rescheduled_at_ist",
      "cancelled_at_ist",
    ].forEach((key) => {
      if (!isSamePromiseDate(r, r[key])) return;
      const minute = minuteOfDay(r[key]);
      if (minute !== null) minutes.push(minute);
    });
  });

  const minMinute = minutes.length ? Math.min(...minutes) : 8 * 60;
  const maxMinute = minutes.length ? Math.max(...minutes) : 20 * 60;
  const rawStartMinute = Math.max(0, minMinute - 45);
  const rawEndMinute = Math.min(24 * 60, maxMinute + 45);
  const startMinute = Math.max(0, Math.floor(rawStartMinute / 60) * 60);
  const endMinute = Math.min(24 * 60, Math.ceil(rawEndMinute / 60) * 60);
  const span = Math.max(1, endMinute - startMinute);
  const pct = (value) => {
    const minute = minuteOfDay(value);
    if (minute === null) return "0%";
    return `${((minute - startMinute) / span) * 100}%`;
  };

  return `
    <div class="timeline-shell">
      <div class="timeline">
        <div class="axis">
          ${axisTicks(startMinute, endMinute)}
        </div>
        ${records.map((r) => timelineRow(r, pct, { startMinute, endMinute, span })).join("")}
      </div>
    </div>
  `;
}

function timelineRow(r, pct, scale) {
  const statusClass = outcomeClass(r);
  const edgeLanes = { before: 0, after: 0 };
  const reason = r.raw_reschedule_reason ? `Reason: ${r.raw_reschedule_reason}` : "";
  const newPromise = r.rescheduled_at_ist
    ? `New promise: ${formatDateTime(r.rescheduled_to_slot_start_at_ist)} to ${formatDateTime(r.rescheduled_to_slot_end_at_ist)}
New agent: ${r.rescheduled_to_agent_name || "Unknown"} (${humanize(r.rescheduled_agent_change_type || "")})
${reason}`.trim()
    : "";
  const changeTooltip = r.rescheduled_at_ist
    ? `Rescheduled at ${formatDateTime(r.rescheduled_at_ist)}
${newPromise}`
    : r.cancelled_at_ist
      ? `Cancelled at ${formatDateTime(r.cancelled_at_ist)}
${reason}`.trim()
      : "";

  return `
    <div class="timeline-row ${statusClass}">
      <div class="row-label">
        ${escapeHtml(`${r.task_type_name} #${r.task_id}`)}
        <small>${escapeHtml(`${formatDate(r.slot_start_at_ist)} | ${r.zone_name || "Unknown zone"}`)}</small>
      </div>
      <div class="slot-bar ${statusClass}" style="left:${pct(r.slot_start_at_ist)}; width:calc(${pct(r.slot_end_at_ist)} - ${pct(r.slot_start_at_ist)});" data-tooltip="${escapeAttr(`Promise slot
${formatDateTime(r.slot_start_at_ist)} to ${formatDateTime(r.slot_end_at_ist)}
Bucket: ${r.promise_bucket}`)}"></div>
      ${marker("scheduled", markerPlacement(r, r.scheduled_start_at_ist, scale, edgeLanes), `Scheduled start\n${formatDateTime(r.scheduled_start_at_ist)}`)}
      ${marker("trip", markerPlacement(r, r.start_trip_at_ist, scale, edgeLanes), `Start trip\n${formatDateTime(r.start_trip_at_ist)}`)}
      ${marker("reached", markerPlacement(r, r.customer_reached_at_ist, scale, edgeLanes), `Reached location\n${formatDateTime(r.customer_reached_at_ist)}`)}
      ${marker("completed", markerPlacement(r, r.completed_at_ist, scale, edgeLanes), `Completed\n${formatDateTime(r.completed_at_ist)}`)}
      ${marker("change", markerPlacement(r, r.rescheduled_at_ist || r.cancelled_at_ist, scale, edgeLanes), changeTooltip)}
      <div class="row-outcome">
        <strong>${escapeHtml(humanizeBucket(r.promise_bucket))}</strong>
        ${r.is_not_met_and_no_blockers ? "No-blocker miss<br>" : ""}
        ${r.has_previous_successful_overlapping_promise_blocker ? "Blocked by previous successful promise<br>" : ""}
        ${escapeHtml(r.raw_reschedule_reason || "")}
      </div>
    </div>
  `;
}

function marker(type, placement, tooltip) {
  if (!placement) return "";
  const edgeClass = placement.edge ? ` edge-marker ${placement.edge}` : "";
  const top = placement.top === null ? "" : ` top:${placement.top}px;`;
  return `<span class="marker ${type}${edgeClass}" style="left:${placement.left};${top}" data-tooltip="${escapeAttr(tooltip)}"></span>`;
}

function markerPlacement(record, timestamp, scale, edgeLanes) {
  if (!timestamp) return null;
  const dt = parseTs(timestamp);
  if (!dt) return null;

  const visibleDate = record.promise_date || timestampDate(record.slot_start_at_ist) || timestampDate(timestamp);
  const markerMs = dt.getTime();
  const startMs = localDateMinuteMs(visibleDate, scale.startMinute);
  const endMs = localDateMinuteMs(visibleDate, scale.endMinute);

  if (markerMs < startMs) {
    return edgePlacement("before", edgeLanes);
  }
  if (markerMs > endMs) {
    return edgePlacement("after", edgeLanes);
  }

  const minute = minuteOfDay(timestamp);
  if (minute === null) return null;
  const left = Math.max(0, Math.min(100, ((minute - scale.startMinute) / scale.span) * 100));
  return { left: `${left}%`, edge: null, top: null };
}

function edgePlacement(edge, edgeLanes) {
  const lane = edgeLanes[edge] || 0;
  edgeLanes[edge] = lane + 1;
  const top = 10 + lane * 14;
  return {
    left: edge === "before" ? "0%" : "100%",
    edge,
    top,
  };
}

function axisTicks(startMinute, endMinute) {
  const ticks = [];
  const span = Math.max(1, endMinute - startMinute);
  const step = span > 12 * 60 ? 120 : 60;
  let current = Math.ceil(startMinute / step) * step;
  while (current <= endMinute) {
    const left = ((current - startMinute) / span) * 100;
    ticks.push(`<span class="tick" style="left:${left}%"><span>${minuteLabel(current)}</span></span>`);
    current += step;
  }
  return ticks.join("");
}

function minuteOfDay(value) {
  const dt = parseTs(value);
  if (!dt) return null;
  return dt.getHours() * 60 + dt.getMinutes();
}

function isSamePromiseDate(record, timestamp) {
  if (!timestamp) return false;
  const promiseDate = record.promise_date || timestampDate(record.slot_start_at_ist);
  return Boolean(promiseDate && timestampDate(timestamp) === promiseDate);
}

function timestampDate(value) {
  return value ? String(value).slice(0, 10) : "";
}

function localDateMinuteMs(dateString, minute) {
  const dayOffset = Math.floor(minute / (24 * 60));
  const minuteOfDate = minute % (24 * 60);
  const base = new Date(`${dateString}T00:00:00`);
  base.setDate(base.getDate() + dayOffset);
  base.setHours(Math.floor(minuteOfDate / 60), minuteOfDate % 60, 0, 0);
  return base.getTime();
}

function minuteLabel(minute) {
  const hour = Math.floor(minute / 60) % 24;
  const mins = minute % 60;
  return `${String(hour).padStart(2, "0")}:${String(mins).padStart(2, "0")}`;
}

function metrics(records) {
  const taskIds = new Set(records.map((r) => r.task_id).filter(Boolean));
  const totalPromises = records.length;
  const validPromises = records.filter((r) => VALID_BUCKETS.has(r.promise_bucket)).length;
  const successCount = records.filter((r) => SUCCESS_BUCKETS.has(r.promise_bucket)).length;
  const failureCount = records.filter((r) => FAILURE_BUCKETS.has(r.promise_bucket)).length;
  const lateRescheduleCount = records.filter((r) => r.promise_bucket === "NOT_MET_RESCHEDULED_AFTER_CUTOFF").length;
  const lateCancelCount = records.filter((r) => r.promise_bucket === "NOT_MET_CANCELLED_AFTER_CUTOFF").length;
  const noBlockerCount = records.filter((r) => r.is_not_met_and_no_blockers).length;
  const excludedCount = records.filter((r) => r.promise_bucket === "EXCLUDED").length;

  return {
    total_tasks: taskIds.size,
    total_promises: totalPromises,
    valid_promises: validPromises,
    success_count: successCount,
    failure_count: failureCount,
    excluded_count: excludedCount,
    late_reschedule_count: lateRescheduleCount,
    late_cancel_count: lateCancelCount,
    not_met_and_no_blockers_count: noBlockerCount,
    success_pct: pct(successCount, validPromises),
    failure_pct: pct(failureCount, validPromises),
    no_blocker_pct: pct(noBlockerCount, validPromises),
    late_reschedule_pct: pct(lateRescheduleCount, validPromises),
    late_cancel_pct: pct(lateCancelCount, validPromises),
  };
}

function aggregateBy(records, keyFn) {
  const map = new Map();
  records.forEach((record) => {
    const key = keyFn(record);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(record);
  });
  return [...map.entries()];
}

function th(key, label) {
  const arrow = state.sort.key === key ? (state.sort.direction === "asc" ? " ↑" : " ↓") : "";
  return `<th data-sort="${key}">${escapeHtml(label + arrow)}</th>`;
}

function bindSortHeaders(root) {
  root.querySelectorAll("th[data-sort]").forEach((header) => {
    header.addEventListener("click", () => {
      const key = header.dataset.sort;
      state.sort = {
        key,
        direction: state.sort.key === key && state.sort.direction === "desc" ? "asc" : "desc",
      };
      render();
    });
  });
}

function sorter() {
  const direction = state.sort.direction === "asc" ? 1 : -1;
  return (a, b) => {
    const av = a[state.sort.key];
    const bv = b[state.sort.key];
    if (typeof av === "number" && typeof bv === "number") return (av - bv) * direction;
    return String(av ?? "").localeCompare(String(bv ?? "")) * direction;
  };
}

function outcomeClass(record) {
  if (record.promise_bucket === "EXCLUDED") return "excluded";
  if (SUCCESS_BUCKETS.has(record.promise_bucket)) return "success";
  if (record.is_not_met_and_no_blockers) return "no-blocker";
  return "blocked";
}

function successBadge(value) {
  const cls = value >= 75 ? "green" : value >= 60 ? "orange" : "red";
  return `<span class="badge ${cls}">${formatPct(value)}%</span>`;
}

function pct(numerator, denominator) {
  return denominator ? (100 * numerator) / denominator : 0;
}

function parseTs(value) {
  if (!value) return null;
  return new Date(value.replace(" ", "T"));
}

function compareTs(a, b) {
  const da = parseTs(a);
  const db = parseTs(b);
  if (!da && !db) return 0;
  if (!da) return 1;
  if (!db) return -1;
  return da.getTime() - db.getTime();
}

const timeFmt = new Intl.DateTimeFormat("en-IN", {
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
  timeZone: "Asia/Kolkata",
});

const dateFmt = new Intl.DateTimeFormat("en-IN", {
  day: "2-digit",
  month: "short",
  timeZone: "Asia/Kolkata",
});

function formatTime(date) {
  return timeFmt.format(date);
}

function formatDateTime(value) {
  const dt = typeof value === "string" ? parseTs(value) : value;
  if (!dt) return "";
  return `${dateFmt.format(dt)} ${timeFmt.format(dt)}`;
}

function formatDate(value) {
  const dt = parseTs(value);
  return dt ? dateFmt.format(dt) : "";
}

function shortDate(dateString) {
  return dateFmt.format(new Date(`${dateString}T00:00:00`));
}

function formatInt(value) {
  return Math.round(Number(value || 0)).toLocaleString("en-IN");
}

function formatCompact(value) {
  const number = Number(value || 0);
  if (Math.abs(number) >= 1000) return `${(number / 1000).toFixed(number >= 10000 ? 0 : 1)}k`;
  return Math.round(number).toLocaleString("en-IN");
}

function formatPct(value) {
  return Number(value || 0).toFixed(1);
}

function humanize(value) {
  return String(value || "")
    .replaceAll("_", " ")
    .toLowerCase()
    .replace(/(^|\s)\w/g, (m) => m.toUpperCase());
}

function humanizeBucket(bucket) {
  return humanize(bucket).replace("Not Met", "Not met").replace("Met With Delay", "Met with delay");
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("\n", "&#10;");
}

document.addEventListener("mousemove", (event) => {
  const target = event.target.closest("[data-tooltip]");
  if (!target) {
    els.tooltip.hidden = true;
    return;
  }
  els.tooltip.textContent = target.dataset.tooltip;
  els.tooltip.hidden = false;
  const offset = 14;
  const rect = els.tooltip.getBoundingClientRect();
  const left = Math.min(event.clientX + offset, window.innerWidth - rect.width - 12);
  const top = Math.min(event.clientY + offset, window.innerHeight - rect.height - 12);
  els.tooltip.style.left = `${left}px`;
  els.tooltip.style.top = `${top}px`;
});

document.addEventListener("click", (event) => {
  const closeButton = event.target.closest("[data-trend-close]");
  if (closeButton) {
    event.preventDefault();
    event.stopPropagation();
    closeMetricTrend(closeButton.closest(".metric"));
    els.tooltip.hidden = true;
    return;
  }

  const trendDate = event.target.closest("[data-trend-date]");
  if (trendDate) {
    event.preventDefault();
    event.stopPropagation();
    openTrendDate(trendDate.dataset.trendDate);
    els.tooltip.hidden = true;
    return;
  }

  const metric = event.target.closest(".metric");
  if (metric) {
    metric.classList.remove("trend-dismissed");
    return;
  }

  if (!metric) {
    document.querySelectorAll(".metric").forEach((metric) => closeMetricTrend(metric, { dismiss: false }));
  }
});

document.addEventListener("pointerout", (event) => {
  const metric = event.target.closest(".metric");
  if (!metric || metric.contains(event.relatedTarget)) return;
  metric.classList.remove("trend-dismissed");
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  document.querySelectorAll(".metric").forEach((metric) => closeMetricTrend(metric, { dismiss: metric.matches(":hover") }));
  els.tooltip.hidden = true;
});

document.addEventListener("mouseleave", () => {
  els.tooltip.hidden = true;
});
