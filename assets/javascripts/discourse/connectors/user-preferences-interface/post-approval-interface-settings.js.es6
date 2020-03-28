const REDIRECT_MODES = ["default", "approved_post", "pa_message", "inbox"];

export default {

    setupComponent(args, component) {

        // Whether user is in Post Approval
        const isPostApproval = Discourse.User.currentProp("groups").find(
            g => g.name.toUpperCase() === Discourse.SiteSettings.post_approval_button_group.toUpperCase()
        ) !== undefined;

        // Current redirect mode setting
        const currentRedirectMode = args.model.get("custom_fields.pa_redirect_mode") || "default";

        // Redirect modes for dropdown
        const redirectModes = REDIRECT_MODES.map(value => {
            return { name: I18n.t(`post_approval.user.redirect.options.${value}`), value };
        });

        // Populate component
        component.setProperties({
            isPostApproval,
            currentRedirectMode,
            redirectModes
        });

        // Update model on redirect mode change
        const updateRedirectMode = function () {
            args.model.set("custom_fields.pa_redirect_mode", component.currentRedirectMode);
        };

        // Listen for dropdown changes
        component.addObserver("currentRedirectMode", updateRedirectMode);

    }

};
