import React from 'npm:react@18.2.0';
import {
  Body,
  Container,
  Head,
  Html,
  Preview,
  Section,
  Tailwind,
  Text,
} from 'npm:@react-email/components@0.0.22';
import { emailTheme } from '../theme.ts';

interface BaseLayoutProps {
  readonly previewText: string;
  readonly headline?: string;
  readonly children: React.ReactNode;
  readonly unsubscribeUrl: string;
}

export function BaseLayout({ previewText, headline, children, unsubscribeUrl }: BaseLayoutProps) {
  return (
    <Html>
      <Head />
      <Preview>{previewText}</Preview>
      <Tailwind>
        <Body className={emailTheme.body}>
          <Section className={emailTheme.canvas}>
            <Container className={emailTheme.container}>
              <div className="flex justify-center">
                <span className={emailTheme.wordmark}>stellr</span>
              </div>
              {headline && <Text className={emailTheme.eyebrow}>{headline}</Text>}
              <div className="mt-8 space-y-6">{children}</div>
              <div className={emailTheme.divider} />
              <Text className={`${emailTheme.footerText} mb-1`}>
                You’re receiving this because you connected with Stellr.
              </Text>
              <Text className={emailTheme.footerText}>
                Stellr · Built for intentional astrology lovers ·{' '}
                <a className={emailTheme.footerLink} href="https://stellr.app/privacy">
                  Privacy
                </a>{' '}
                ·{' '}
                <a className={emailTheme.footerLink} href={unsubscribeUrl}>
                  Unsubscribe
                </a>
              </Text>
            </Container>
          </Section>
        </Body>
      </Tailwind>
    </Html>
  );
}
