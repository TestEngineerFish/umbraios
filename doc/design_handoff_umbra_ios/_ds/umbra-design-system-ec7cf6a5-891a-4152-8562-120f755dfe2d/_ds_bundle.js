/* @ds-bundle: {"format":4,"namespace":"UmbraDesignSystem_ec7cf6","components":[{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"Card","sourcePath":"components/core/Card.jsx"},{"name":"CollapsibleText","sourcePath":"components/core/CollapsibleText.jsx"},{"name":"EmptyState","sourcePath":"components/core/EmptyState.jsx"},{"name":"ErrorCard","sourcePath":"components/core/ErrorCard.jsx"},{"name":"FilterChip","sourcePath":"components/core/FilterChip.jsx"},{"name":"Input","sourcePath":"components/core/Input.jsx"},{"name":"NavRail","sourcePath":"components/core/NavRail.jsx"},{"name":"ProgressBar","sourcePath":"components/core/ProgressBar.jsx"},{"name":"SectionHeader","sourcePath":"components/core/SectionHeader.jsx"},{"name":"StatusBadge","sourcePath":"components/core/StatusBadge.jsx"},{"name":"StatusDot","sourcePath":"components/core/StatusDot.jsx"},{"name":"Switch","sourcePath":"components/core/Switch.jsx"}],"sourceHashes":{"components/core/Button.jsx":"57178a121125","components/core/Card.jsx":"af3d61d846e1","components/core/CollapsibleText.jsx":"0b165678d21c","components/core/EmptyState.jsx":"2de4c849d182","components/core/ErrorCard.jsx":"bc4590a672f3","components/core/FilterChip.jsx":"ebe72387ad36","components/core/Input.jsx":"6e05eb1afb6d","components/core/NavRail.jsx":"ece1b243c787","components/core/ProgressBar.jsx":"38fbeab67372","components/core/SectionHeader.jsx":"80827995df97","components/core/StatusBadge.jsx":"e9e57f660197","components/core/StatusDot.jsx":"e6a4c5b67821","components/core/Switch.jsx":"0b8d6624d85d"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.UmbraDesignSystem_ec7cf6 = window.UmbraDesignSystem_ec7cf6 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/core/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const BASE = {
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 'var(--sp-2)',
  fontFamily: 'var(--font-sans)',
  fontSize: 'var(--fs-body)',
  whiteSpace: 'nowrap',
  borderRadius: 'var(--radius-md)',
  cursor: 'pointer',
  flex: 'none',
  transition: 'background .12s ease, border-color .12s ease, color .12s ease'
};
const VARIANTS = {
  primary: {
    background: 'var(--orange)',
    color: '#fff',
    border: '1px solid transparent',
    fontWeight: 'var(--fw-medium)'
  },
  secondary: {
    background: 'var(--card)',
    color: 'var(--text)',
    border: '1px solid var(--border)'
  },
  ghost: {
    background: 'transparent',
    color: 'var(--muted)',
    border: '1px solid transparent'
  },
  destructive: {
    background: 'transparent',
    color: 'var(--danger)',
    border: '1px solid var(--danger)'
  }
};
const HOVER = {
  primary: {
    background: 'var(--orange-deep)'
  },
  secondary: {
    borderColor: 'var(--orange)',
    color: 'var(--orange-text)'
  },
  ghost: {
    background: 'var(--hover)',
    color: 'var(--text)'
  },
  destructive: {
    background: 'var(--danger)',
    color: '#fff'
  }
};
function Button({
  variant = 'secondary',
  size = 'md',
  icon,
  children,
  disabled,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const height = size === 'sm' ? 'var(--control-h-compact)' : 'var(--control-h)';
  const pad = size === 'sm' ? '0 11px' : '0 16px';
  const s = {
    ...BASE,
    ...VARIANTS[variant],
    height,
    padding: pad,
    ...(hover && !disabled ? HOVER[variant] : null),
    ...(disabled ? {
      background: 'var(--chip)',
      color: 'var(--faint)',
      border: '1px solid var(--border)',
      cursor: 'not-allowed'
    } : null),
    ...style
  };
  return /*#__PURE__*/React.createElement("button", _extends({}, rest, {
    disabled: disabled,
    style: s,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false)
  }), icon, children ? /*#__PURE__*/React.createElement("span", {
    style: {
      whiteSpace: 'nowrap',
      flex: 'none'
    }
  }, children) : null);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/Card.jsx
try { (() => {
function Card({
  title,
  meta,
  actions,
  selected,
  onClick,
  children,
  padding = 'var(--sp-6)',
  style
}) {
  const [hover, setHover] = React.useState(false);
  return /*#__PURE__*/React.createElement("div", {
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      background: 'var(--card)',
      border: '1px solid ' + (selected || hover && onClick ? 'var(--orange)' : 'var(--border)'),
      borderRadius: 'var(--radius-xl)',
      padding,
      minWidth: 0,
      cursor: onClick ? 'pointer' : 'default',
      transition: 'border-color .12s ease',
      ...style
    }
  }, title || actions ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'flex-start',
      gap: '12px',
      marginBottom: children ? '10px' : 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, title ? /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-item-title)',
      fontWeight: 'var(--fw-semibold)',
      color: 'var(--text)',
      lineHeight: 'var(--lh-title)',
      textWrap: 'pretty'
    }
  }, title) : null, meta ? /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: '4px',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      color: 'var(--faint)'
    }
  }, meta) : null), actions ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--sp-2)',
      flex: 'none'
    }
  }, actions) : null) : null, children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Card.jsx", error: String((e && e.message) || e) }); }

// components/core/CollapsibleText.jsx
try { (() => {
function CollapsibleText({
  text,
  lines = 2,
  threshold = 62,
  maxHeight = 132,
  style
}) {
  const [open, setOpen] = React.useState(false);
  const long = (text || '').length > threshold;
  const clamped = {
    display: '-webkit-box',
    WebkitLineClamp: lines,
    WebkitBoxOrient: 'vertical',
    overflow: 'hidden'
  };
  return /*#__PURE__*/React.createElement("div", {
    style: style
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-body)',
      lineHeight: 'var(--lh-body)',
      color: 'var(--muted)',
      textWrap: 'pretty',
      ...(open ? {
        maxHeight,
        overflowY: 'auto'
      } : long ? clamped : null)
    }
  }, text), long ? /*#__PURE__*/React.createElement("button", {
    onClick: () => setOpen(!open),
    style: {
      marginTop: '3px',
      padding: 0,
      border: 'none',
      background: 'transparent',
      color: 'var(--orange-text)',
      cursor: 'pointer',
      whiteSpace: 'nowrap',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      fontWeight: 'var(--fw-medium)'
    }
  }, open ? '收起描述' : '展开描述') : null);
}
Object.assign(__ds_scope, { CollapsibleText });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/CollapsibleText.jsx", error: String((e && e.message) || e) }); }

// components/core/EmptyState.jsx
try { (() => {
const BOX = /*#__PURE__*/React.createElement("svg", {
  width: "24",
  height: "24",
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "var(--faint)",
  strokeWidth: "1.6",
  strokeLinecap: "round",
  strokeLinejoin: "round"
}, /*#__PURE__*/React.createElement("path", {
  d: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"
}));
function EmptyState({
  icon,
  title,
  hint,
  action,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      border: '1px dashed var(--border)',
      borderRadius: 'var(--radius-lg)',
      padding: '22px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '8px',
      fontFamily: 'var(--font-sans)',
      ...style
    }
  }, icon || BOX, /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 'var(--fs-body)',
      color: 'var(--muted)',
      whiteSpace: 'nowrap'
    }
  }, title), hint ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 'var(--fs-meta)',
      color: 'var(--faint)',
      textAlign: 'center',
      lineHeight: '1.6',
      textWrap: 'pretty',
      maxWidth: '320px'
    }
  }, hint) : null, action ? /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: '6px'
    }
  }, action) : null);
}
Object.assign(__ds_scope, { EmptyState });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/EmptyState.jsx", error: String((e && e.message) || e) }); }

// components/core/ErrorCard.jsx
try { (() => {
function ErrorCard({
  what,
  why,
  actions,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: 'var(--danger-soft)',
      borderRadius: 'var(--radius-lg)',
      padding: '14px',
      display: 'flex',
      gap: '9px',
      alignItems: 'flex-start',
      ...style
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "14",
    height: "14",
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "var(--danger)",
    strokeWidth: "2.2",
    strokeLinecap: "round",
    style: {
      flex: 'none',
      marginTop: '2px'
    }
  }, /*#__PURE__*/React.createElement("circle", {
    cx: "12",
    cy: "12",
    r: "9"
  }), /*#__PURE__*/React.createElement("path", {
    d: "m15 9-6 6M9 9l6 6"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-body)',
      fontWeight: 'var(--fw-semibold)',
      color: 'var(--text)',
      lineHeight: '1.55',
      textWrap: 'pretty'
    }
  }, what), why ? /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: '5px',
      fontFamily: 'var(--font-sans)',
      fontSize: '12px',
      lineHeight: 'var(--lh-body)',
      color: 'var(--muted)',
      textWrap: 'pretty'
    }
  }, why) : null, actions ? /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: '11px',
      display: 'flex',
      gap: '8px',
      flexWrap: 'wrap'
    }
  }, actions) : null));
}
Object.assign(__ds_scope, { ErrorCard });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/ErrorCard.jsx", error: String((e && e.message) || e) }); }

// components/core/FilterChip.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function FilterChip({
  active,
  count,
  children,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  return /*#__PURE__*/React.createElement("button", _extends({}, rest, {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: '6px',
      flex: 'none',
      padding: '5px 12px',
      borderRadius: 'var(--radius-sm)',
      cursor: 'pointer',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      whiteSpace: 'nowrap',
      fontWeight: active ? 'var(--fw-medium)' : 'var(--fw-regular)',
      background: active ? 'var(--orange-soft)' : 'var(--card)',
      color: active ? 'var(--orange-text)' : 'var(--muted)',
      border: '1px solid ' + (active || hover ? 'var(--orange)' : 'var(--border)'),
      ...style
    }
  }), children, count != null ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: '10.5px',
      fontWeight: 'var(--fw-semibold)',
      color: active ? 'var(--orange-text)' : 'var(--faint)'
    }
  }, count) : null);
}
Object.assign(__ds_scope, { FilterChip });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/FilterChip.jsx", error: String((e && e.message) || e) }); }

// components/core/Input.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const SEARCH = /*#__PURE__*/React.createElement("svg", {
  width: "13",
  height: "13",
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "var(--faint)",
  strokeWidth: "2",
  strokeLinecap: "round",
  style: {
    flex: 'none'
  }
}, /*#__PURE__*/React.createElement("circle", {
  cx: "11",
  cy: "11",
  r: "7"
}), /*#__PURE__*/React.createElement("path", {
  d: "m20 20-4.3-4.3"
}));
function Input({
  icon,
  search,
  style,
  wrapStyle,
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const lead = search ? SEARCH : icon;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: '8px',
      minWidth: 0,
      background: 'var(--bg)',
      border: '1px solid ' + (focus ? 'var(--orange)' : 'var(--border)'),
      borderRadius: 'var(--radius-md)',
      padding: '7px 11px',
      ...wrapStyle
    }
  }, lead, /*#__PURE__*/React.createElement("input", _extends({}, rest, {
    onFocus: e => {
      setFocus(true);
      rest.onFocus && rest.onFocus(e);
    },
    onBlur: e => {
      setFocus(false);
      rest.onBlur && rest.onBlur(e);
    },
    style: {
      flex: 1,
      minWidth: 0,
      border: 'none',
      background: 'transparent',
      outline: 'none',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-body)',
      color: 'var(--text)',
      ...style
    }
  })));
}
Object.assign(__ds_scope, { Input });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Input.jsx", error: String((e && e.message) || e) }); }

// components/core/NavRail.jsx
try { (() => {
function NavRail({
  items = [],
  active,
  onSelect,
  brand = 'Umbra',
  style
}) {
  return /*#__PURE__*/React.createElement("nav", {
    style: {
      width: 'var(--nav-w)',
      flex: 'none',
      background: 'var(--nav)',
      display: 'flex',
      flexDirection: 'column',
      padding: '14px 10px',
      gap: '2px',
      fontFamily: 'var(--font-sans)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: '9px',
      padding: '4px 6px 14px'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: '25px',
      height: '25px',
      flex: 'none',
      borderRadius: 'var(--radius-sm)',
      background: 'var(--orange)',
      color: '#fff',
      fontWeight: 700,
      fontSize: '14px',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, brand.slice(0, 1)), /*#__PURE__*/React.createElement("span", {
    style: {
      color: '#fff',
      fontWeight: 'var(--fw-semibold)',
      fontSize: '14px',
      whiteSpace: 'nowrap'
    }
  }, brand)), items.map(it => {
    const on = it.id === active;
    return /*#__PURE__*/React.createElement("button", {
      key: it.id,
      onClick: () => onSelect && onSelect(it.id),
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: '9px',
        width: '100%',
        padding: '7px 9px',
        border: 'none',
        borderRadius: 'var(--radius-md)',
        cursor: 'pointer',
        background: on ? 'var(--orange)' : 'transparent',
        color: on ? '#fff' : 'rgba(255,255,255,.62)',
        fontFamily: 'inherit',
        fontSize: '12.5px',
        fontWeight: on ? 'var(--fw-medium)' : 'var(--fw-regular)'
      }
    }, it.icon, /*#__PURE__*/React.createElement("span", {
      style: {
        flex: 1,
        textAlign: 'left',
        whiteSpace: 'nowrap'
      }
    }, it.label), it.badge ? /*#__PURE__*/React.createElement("span", {
      style: {
        minWidth: '16px',
        height: '16px',
        padding: '0 4px',
        flex: 'none',
        borderRadius: 'var(--radius-pill)',
        background: on ? 'rgba(255,255,255,.24)' : 'var(--orange)',
        color: '#fff',
        fontSize: '10px',
        fontWeight: 'var(--fw-semibold)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center'
      }
    }, it.badge) : null);
  }));
}
Object.assign(__ds_scope, { NavRail });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/NavRail.jsx", error: String((e && e.message) || e) }); }

// components/core/ProgressBar.jsx
try { (() => {
function ProgressBar({
  value = 0,
  showValue = true,
  style
}) {
  const pct = Math.max(0, Math.min(100, value));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: '10px',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      height: 'var(--progress-h)',
      borderRadius: 'var(--radius-pill)',
      background: 'var(--track)',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'block',
      width: pct + '%',
      height: '100%',
      background: 'var(--orange)',
      borderRadius: 'var(--radius-pill)'
    }
  })), showValue ? /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 'none',
      whiteSpace: 'nowrap',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      fontWeight: 'var(--fw-semibold)',
      color: 'var(--orange-text)'
    }
  }, Math.round(pct), "%") : null);
}
Object.assign(__ds_scope, { ProgressBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/ProgressBar.jsx", error: String((e && e.message) || e) }); }

// components/core/SectionHeader.jsx
try { (() => {
function SectionHeader({
  index,
  title,
  note,
  actions,
  rule = true,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: '11px',
      fontFamily: 'var(--font-sans)',
      marginBottom: 'var(--sp-5)',
      ...style
    }
  }, index ? /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 'none',
      whiteSpace: 'nowrap',
      fontSize: 'var(--fs-field-label)',
      fontWeight: 700,
      letterSpacing: '.1em',
      color: 'var(--orange-text)'
    }
  }, index) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 'none',
      whiteSpace: 'nowrap',
      fontSize: 'var(--fs-section-title)',
      fontWeight: 'var(--fw-bold)',
      color: 'var(--text)'
    }
  }, title), rule ? /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      height: '1px',
      background: 'var(--border)'
    }
  }) : /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), note ? /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 'none',
      whiteSpace: 'nowrap',
      fontSize: 'var(--fs-meta)',
      color: 'var(--faint)'
    }
  }, note) : null, actions ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--sp-2)',
      flex: 'none'
    }
  }, actions) : null);
}
Object.assign(__ds_scope, { SectionHeader });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/SectionHeader.jsx", error: String((e && e.message) || e) }); }

// components/core/StatusBadge.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const P = {
  strokeWidth: 2.4,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
  fill: 'none',
  stroke: 'currentColor',
  width: 11,
  height: 11,
  viewBox: '0 0 24 24'
};
const MAP = {
  running: {
    label: '运行中',
    fg: 'var(--orange-text)',
    bg: 'var(--orange-soft)',
    d: 'M20 12a8 8 0 1 1-2.3-5.7'
  },
  done: {
    label: '已完成',
    fg: 'var(--success)',
    bg: 'var(--success-soft)',
    d: 'M20 6 9 17l-5-5'
  },
  warning: {
    label: '需确认',
    fg: 'var(--warning)',
    bg: 'var(--warning-soft)',
    d: 'M12 9v4M12 17v.01M10.3 3.9 2.4 18a1.8 1.8 0 0 0 1.6 2.7h16a1.8 1.8 0 0 0 1.6-2.7L13.7 3.9a1.8 1.8 0 0 0-3.4 0Z'
  },
  failed: {
    label: '失败',
    fg: 'var(--danger)',
    bg: 'var(--danger-soft)',
    d: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM15 9l-6 6M9 9l6 6'
  },
  queued: {
    label: '排队中',
    fg: 'var(--muted)',
    bg: 'var(--chip)',
    d: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM12 7v5l3 2'
  }
};
function StatusBadge({
  status = 'queued',
  label,
  style
}) {
  const t = MAP[status] || MAP.queued;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: '6px',
      flex: 'none',
      padding: '4px 11px',
      borderRadius: 'var(--radius-pill)',
      background: t.bg,
      color: t.fg,
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      fontWeight: 'var(--fw-medium)',
      whiteSpace: 'nowrap',
      ...style
    }
  }, /*#__PURE__*/React.createElement("svg", _extends({}, P, {
    style: {
      flex: 'none'
    }
  }), /*#__PURE__*/React.createElement("path", {
    d: t.d
  })), label || t.label);
}
Object.assign(__ds_scope, { StatusBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/StatusBadge.jsx", error: String((e && e.message) || e) }); }

// components/core/StatusDot.jsx
try { (() => {
const TONE = {
  success: {
    c: 'var(--success)',
    s: 'var(--success-soft)'
  },
  warning: {
    c: 'var(--warning)',
    s: 'var(--warning-soft)'
  },
  danger: {
    c: 'var(--danger)',
    s: 'var(--danger-soft)'
  },
  idle: {
    c: 'var(--faint)',
    s: 'var(--chip)'
  }
};
function StatusDot({
  tone = 'success',
  children,
  bordered = true,
  style
}) {
  const t = TONE[tone] || TONE.idle;
  const dot = /*#__PURE__*/React.createElement("span", {
    style: {
      width: 'var(--status-dot)',
      height: 'var(--status-dot)',
      flex: 'none',
      borderRadius: 'var(--radius-pill)',
      background: t.c,
      boxShadow: '0 0 0 3px ' + t.s
    }
  });
  if (!children) return dot;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: '7px',
      flex: 'none',
      padding: '3px 10px',
      borderRadius: 'var(--radius-pill)',
      border: bordered ? '1px solid var(--border)' : 'none',
      background: bordered ? 'var(--card)' : 'transparent',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-meta)',
      color: 'var(--muted)',
      whiteSpace: 'nowrap',
      ...style
    }
  }, dot, children);
}
Object.assign(__ds_scope, { StatusDot });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/StatusDot.jsx", error: String((e && e.message) || e) }); }

// components/core/Switch.jsx
try { (() => {
function Switch({
  checked,
  onChange,
  disabled,
  label,
  style
}) {
  const track = /*#__PURE__*/React.createElement("span", {
    role: "switch",
    "aria-checked": !!checked,
    tabIndex: disabled ? -1 : 0,
    onClick: () => !disabled && onChange && onChange(!checked),
    style: {
      position: 'relative',
      flex: 'none',
      cursor: disabled ? 'not-allowed' : 'pointer',
      width: 'var(--switch-w)',
      height: 'var(--switch-h)',
      borderRadius: 'var(--radius-pill)',
      background: checked ? 'var(--orange)' : 'var(--track)',
      opacity: disabled ? .5 : 1,
      transition: 'background .15s ease'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: '2.5px',
      left: checked ? '18px' : '2.5px',
      width: '16px',
      height: '16px',
      borderRadius: 'var(--radius-pill)',
      background: checked ? '#fff' : 'var(--card)',
      border: checked ? 'none' : '1px solid var(--border)',
      transition: 'left .15s ease'
    }
  }));
  if (!label) return track;
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: '11px',
      ...style
    }
  }, track, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--fs-body)',
      color: 'var(--text)',
      textWrap: 'pretty'
    }
  }, label));
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Switch.jsx", error: String((e && e.message) || e) }); }

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.CollapsibleText = __ds_scope.CollapsibleText;

__ds_ns.EmptyState = __ds_scope.EmptyState;

__ds_ns.ErrorCard = __ds_scope.ErrorCard;

__ds_ns.FilterChip = __ds_scope.FilterChip;

__ds_ns.Input = __ds_scope.Input;

__ds_ns.NavRail = __ds_scope.NavRail;

__ds_ns.ProgressBar = __ds_scope.ProgressBar;

__ds_ns.SectionHeader = __ds_scope.SectionHeader;

__ds_ns.StatusBadge = __ds_scope.StatusBadge;

__ds_ns.StatusDot = __ds_scope.StatusDot;

__ds_ns.Switch = __ds_scope.Switch;

})();
