package main

import "core:fmt"
import "core:os"

import "core/log"
import "app"
import "core/settings"

main :: proc() {
	// Handle CLI arguments
	action := cli_handle_args(os.args)
	switch action {
	case .Exit_Success:
		os.exit(0)
	case .Exit_Failure:
		os.exit(1)
	case .Continue:
		// proceed
	}

	application := app.create(settings.WINDOW_WIDTH, settings.WINDOW_HEIGHT, "suckless-odin — Icosphere Phong")
	if application == nil {
		log.log_error("suckless-odin.main", "Failed to create application")
		os.exit(1)
	}
	defer app.destroy(application)

	if !app.init(application) {
		log.log_error("suckless-odin.main", "Failed to initialize application")
		os.exit(1)
	}

	app.run(application)
}
