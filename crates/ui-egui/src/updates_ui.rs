//! This edition only opens its verified-download page when explicitly requested.
//! It never constructs an upstream updater, checks at startup or replaces an executable.

use crate::{SheetApp, distribution};

#[derive(Default)]
pub(crate) struct Runtime {
    manual: bool,
}

/// Keep the existing command API, but ignore automatic startup-check requests.
pub(crate) fn start(app: &mut SheetApp, manual: bool) {
    app.updates_rt.manual |= manual;
}

/// Open the publisher's page once for an explicit request; no network task is created here.
pub(crate) fn tick(app: &mut SheetApp, _ctx: &egui::Context) {
    if !std::mem::take(&mut app.updates_rt.manual) {
        return;
    }
    if let Some(open) = &app.services.open_url {
        open(distribution::DOWNLOAD_URL);
    } else {
        app.message = Some((distribution::APP_NAME.into(), format!("Download verified releases manually: {}", distribution::DOWNLOAD_URL)));
    }
}

/// There is no automatic-update prompt or close/restart action in this edition.
pub(crate) fn show(_app: &mut SheetApp, _ctx: &egui::Context) {}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::{start, tick};
    use crate::{Services, SheetApp, distribution};

    #[test]
    fn startup_is_silent_and_manual_command_only_opens_the_edition_download_page() {
        let opened = Rc::new(RefCell::new(Vec::new()));
        let sink = opened.clone();
        let services = Services { open_url: Some(Box::new(move |url| sink.borrow_mut().push(url.to_owned()))), ..Default::default() };
        let mut app = SheetApp::new(gridcraft_engine::Session::new(), services);
        let ctx = egui::Context::default();
        start(&mut app, false);
        tick(&mut app, &ctx);
        assert!(opened.borrow().is_empty(), "startup must never check or open an upstream release");
        assert!(app.run("app.checkForUpdates", serde_json::json!({})).is_ok());
        tick(&mut app, &ctx);
        tick(&mut app, &ctx);
        assert_eq!(*opened.borrow(), [distribution::DOWNLOAD_URL]);
        assert!(app.message.is_none());
    }
}
