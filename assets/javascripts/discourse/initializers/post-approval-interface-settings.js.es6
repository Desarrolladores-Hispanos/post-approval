import { withPluginApi } from "discourse/lib/plugin-api"

export default {
	name: "post-approval-interface-settings",

	initialize() {
		if(!Discourse.SiteSettings.post_approval_enabled || !Discourse.SiteSettings.post_approval_redirect_enabled)
            return;

		withPluginApi("0.8.24", api => {
			api.modifyClass("controller:preferences/interface", {
				actions: {
					save() {
						this.get("saveAttrNames").push("custom_fields")
						this._super()
					}
				}
			})
		})
	}
}
