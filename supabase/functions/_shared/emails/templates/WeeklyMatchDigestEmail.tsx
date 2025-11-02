import React from 'npm:react@18.2.0';
import { Heading, Section, Text, Button } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface MatchCard {
  readonly name: string;
  readonly sunSign: string;
  readonly compatibilityScore: number;
  readonly highlight: string;
  readonly profileUrl: string;
}

interface WeeklyMatchDigestProps {
  readonly name?: string;
  readonly matches: MatchCard[];
  readonly unsubscribeUrl: string;
  readonly exploreLink: string;
}

export const WeeklyMatchDigestEmail: React.FC<WeeklyMatchDigestProps> = ({
  name,
  matches,
  unsubscribeUrl,
  exploreLink,
}) => {
  const firstName = name?.split(' ')[0] || 'Astro Babe';
  return (
    <BaseLayout
      previewText={`Your Stellr matches are ready, ${firstName}`}
      headline="Weekly match digest"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Your top matches this week</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>
          Our astro-algorithm scanned your chart and surfaced the people vibing closest to your frequency.
        </Text>
        {matches.slice(0, 4).map((match) => (
          <Section key={match.name} className={emailTheme.card}>
            <Text className="text-lg font-semibold text-[#f5d0fe]">{match.name}</Text>
            <Text className={emailTheme.mutedText}>
              {match.sunSign} • {match.compatibilityScore}% cosmic sync
            </Text>
            <Text className={`${emailTheme.bodyText} mt-2`}>{match.highlight}</Text>
            <Button href={match.profileUrl} className={`${emailTheme.softButton} mt-4`}>
              View their profile
            </Button>
          </Section>
        ))}
        {matches.length === 0 && (
          <Text className={emailTheme.mutedText}>
            We’re brewing new matches based on your chart—check back soon.
          </Text>
        )}
        <Button href={exploreLink} className={emailTheme.primaryButton}>
          Explore the Stellr universe
        </Button>
      </Section>
    </BaseLayout>
  );
};
