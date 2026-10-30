//! Public embedding APIs must not leave a discarded analysis blocking its session.
use std::sync::Arc;

use gridcraft_core::{CellRef, Value};
use gridcraft_engine::Session;
use serde_json::json;

/// An early finish keeps its job; a ready job with an externally changed source is discarded atomically.
#[test]
fn finish_discards_changed_source_but_retains_an_early_job() {
    let mut session = Session::new();
    session.new_workbook();
    session.execute("cell.set", json!({"cell":"A1","input":"10"})).unwrap();
    session.execute("cell.set", json!({"cell":"B1","input":"=A1*2"})).unwrap();
    let params = json!({"inputs":[{"cell":"Sheet1!A1","min":0,"max":1}],"outputs":["Sheet1!B1"],"iterations":8,"samples":false,"seed":42});
    let job = session.execute("analysis.start", json!({"params":params,"autoAdvance":false})).unwrap()["job"].clone();
    assert!(session.execute("analysis.finish", json!({"job":job})).is_err());
    assert!(session.analysis_active(), "early finish must preserve pending work");
    for _ in 0..8 {
        if session.execute("analysis.step", json!({"job":job,"trials":2})).unwrap()["state"] == "ready" {
            break;
        }
    }
    assert_eq!(session.analysis_progress().unwrap()["state"], "ready");
    let mut changed = (*session.doc().unwrap().wb).clone();
    changed.sheet_mut(0).unwrap().set_value(CellRef::new(0, 0), Value::Number(99.0));
    let changed = Arc::new(changed);
    session.doc_mut().unwrap().wb = changed.clone();
    let (undo, redo, revision) = {
        let doc = session.doc().unwrap();
        (doc.undo.len(), doc.redo.len(), doc.revision)
    };
    let error = session.execute("analysis.finish", json!({"job":job})).unwrap_err();
    assert!(error.to_string().contains("source workbook changed"));
    assert!(!session.analysis_active(), "source rejection must discard the unusable job");
    let doc = session.doc().unwrap();
    assert!(Arc::ptr_eq(&doc.wb, &changed));
    assert_eq!((doc.undo.len(), doc.redo.len(), doc.revision), (undo, redo, revision));
    assert_eq!(doc.wb.sheets.len(), 1, "a rejected finish must not publish a report");
    assert_eq!(doc.wb.sheet(0).unwrap().value(CellRef::new(0, 0)), Value::Number(99.0));
    session.execute("cell.set", json!({"cell":"A1","input":"12"})).unwrap();
    let next = session.execute("analysis.start", json!({"params":params,"autoAdvance":false})).unwrap()["job"].clone();
    assert_ne!(next, job);
    session.execute("analysis.cancel", json!({"job":next})).unwrap();
}
