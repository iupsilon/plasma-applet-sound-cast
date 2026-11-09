# Install the sound-cast Plasma 6 widget.
#
#   make install [DESTDIR=...] [PREFIX=/usr]   install widget, icon, translations, sound-cast-move
#   make uninstall
#   make pot                                   re-extract strings to po/*.pot
#   make merge                                 update po/*.po from the template
#   make test-install / test-uninstall         install for the current user only (kpackagetool6)

APPLET   := org.soundcast.status
DOMAIN   := plasma_applet_$(APPLET)
PREFIX   ?= /usr
DESTDIR  ?=
PLASMOID := $(DESTDIR)$(PREFIX)/share/plasma/plasmoids/$(APPLET)
POT      := po/$(DOMAIN).pot
LANGS    := $(basename $(notdir $(wildcard po/*.po)))

.PHONY: all install uninstall pot merge test-install test-uninstall

all:
	@echo "Nothing to build. Run 'make install' (see Makefile)."

install:
	install -d $(PLASMOID)
	cp -r package/. $(PLASMOID)/
	find $(PLASMOID) -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
	install -Dm644 package/contents/icons/sound-cast-symbolic.svg \
		$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/sound-cast-symbolic.svg
	install -Dm755 package/contents/code/sound-cast-move $(DESTDIR)$(PREFIX)/bin/sound-cast-move
	for lang in $(LANGS); do \
		install -d $(DESTDIR)$(PREFIX)/share/locale/$$lang/LC_MESSAGES; \
		msgfmt -o $(DESTDIR)$(PREFIX)/share/locale/$$lang/LC_MESSAGES/$(DOMAIN).mo po/$$lang.po; \
	done

uninstall:
	rm -rf $(PLASMOID)
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/sound-cast-symbolic.svg
	rm -f $(DESTDIR)$(PREFIX)/bin/sound-cast-move
	for lang in $(LANGS); do rm -f $(DESTDIR)$(PREFIX)/share/locale/$$lang/LC_MESSAGES/$(DOMAIN).mo; done

pot:
	xgettext --from-code=UTF-8 --language=JavaScript -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 \
		--package-name=$(APPLET) -o $(POT) package/contents/ui/*.qml

merge: pot
	for lang in $(LANGS); do msgmerge --quiet --update --backup=none po/$$lang.po $(POT); done
	msgfmt --check --statistics -o /dev/null po/*.po

test-install:
	kpackagetool6 -t Plasma/Applet -i package || kpackagetool6 -t Plasma/Applet -u package

test-uninstall:
	kpackagetool6 -t Plasma/Applet -r $(APPLET)
