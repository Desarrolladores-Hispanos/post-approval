export default {
  setupComponent(args, component) {
    // Find a group with setting name in the user's groups:
    const group = Discourse.User.currentProp("groups").find(
        g => g.name.toUpperCase() === Discourse.SiteSettings.post_approval_button_group.toUpperCase()
    );
    // Set visibility of button based on whether group was found:
    component.set("isPostApproval", group !== undefined);
  }
};