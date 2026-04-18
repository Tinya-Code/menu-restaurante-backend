import { Controller, Get, Param } from '@nestjs/common';
import { RestaurantsService } from './restaurants.service';

@Controller('resources/restaurants')
export class RestaurantsController {
  constructor(private readonly restaurantsService: RestaurantsService) {}

  @Get(':slug/full')
  findOneFull(@Param('slug') slug: string) {
    return this.restaurantsService.findOneBySlugFull(slug);
  }

  @Get(':slug/location')
  getLocation(@Param('slug') slug: string) {
    return this.restaurantsService.getLocationBySlug(slug);
  }
}
